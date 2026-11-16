import Testing
@testable import Persona

struct WatchAnswersTests {
    @Test func goneResponseFinishesWithoutRestoringAnErrorCard() {
        var answers = WatchAnswers()
        let request = Interaction(id: "expired", machineID: "machine", sessionID: "session", kind: .permission)
        var cards = [request]
        #expect(answers.begin(request, in: &cards))
        #expect(answers.receiveFailure(request, status: 410, message: "Gone", in: &cards))
        #expect(cards.isEmpty)
        #expect(answers.answering.isEmpty)
        #expect(answers.errors.isEmpty)
        #expect(answers.reconcile([request]).isEmpty)
    }

    @Test func otherHTTPFailuresAndTransportFailuresRestoreTheCard() {
        for status in [403, 500, nil] as [Int?] {
            var answers = WatchAnswers()
            let request = Interaction(id: "failed", machineID: "machine", sessionID: "session", kind: .permission)
            var cards = [request]
            #expect(answers.begin(request, in: &cards))
            #expect(!answers.receiveFailure(request, status: status, message: "Unavailable", in: &cards))
            #expect(cards == [request])
            #expect(answers.errors[request.uid] == "Unavailable")
        }
    }
    private let request = Interaction(id: "request", machineID: "machine", sessionID: "session", kind: .permission)

    @Test func pendingDetailRetainsTheOriginalRequestAndRequiresBothGroupAndID() {
        var original = request
        original.reason = "Review this change"
        var other = original
        other.group = "other"
        other.reason = "Review another change"
        var answers = WatchAnswers()
        var cards = [original, other]
        #expect(answers.request(group: original.group, id: original.id) == nil)
        #expect(answers.begin(original, in: &cards))
        #expect(answers.begin(other, in: &cards))
        #expect(cards.isEmpty)
        #expect(answers.request(group: original.group, id: original.id) == original)
        #expect(answers.request(group: other.group, id: other.id) == other)
        #expect(answers.request(group: "missing", id: original.id) == nil)
        #expect(answers.request(group: original.group, id: "missing") == nil)
        #expect(answers.reconcile([]).isEmpty)
        #expect(answers.request(group: original.group, id: original.id) == original)
        #expect(answers.request(group: other.group, id: other.id) == other)
    }

    @Test func completionClearsOnlyItsOwnPendingDetail() {
        var other = request
        other.group = "other"
        var answers = WatchAnswers()
        var cards = [request, other]
        #expect(answers.begin(request, in: &cards))
        #expect(answers.begin(other, in: &cards))
        answers.complete(request)
        #expect(answers.request(group: request.group, id: request.id) == nil)
        #expect(answers.request(group: other.group, id: other.id) == other)
        #expect(answers.answering == [other.uid])
        #expect(answers.reconcile([request, other]).isEmpty)
        #expect(answers.request(group: request.group, id: request.id) == nil)
    }

    @Test func failureClearsOnlyItsOwnPendingDetailAndRetryRestoresIt() {
        var other = request
        other.group = "other"
        var answers = WatchAnswers()
        var cards = [request, other]
        #expect(answers.begin(request, in: &cards))
        #expect(answers.begin(other, in: &cards))
        answers.fail(request, message: "Offline", in: &cards)
        #expect(cards == [request])
        #expect(answers.request(group: request.group, id: request.id) == nil)
        #expect(answers.request(group: other.group, id: other.id) == other)
        #expect(answers.answering == [other.uid])
        #expect(answers.begin(request, in: &cards))
        #expect(answers.request(group: request.group, id: request.id) == request)
        #expect(answers.errors.isEmpty)
    }

    @Test func diagnosticBeginLatencyMeasuresOnlyPureStateFeedback() {
        let clock = ContinuousClock()
        let iterations = 1_000
        var samples: [Duration] = []
        samples.reserveCapacity(iterations)
        for _ in 0..<iterations {
            var answers = WatchAnswers()
            var cards = [request]
            let started = clock.now
            let began = answers.begin(request, in: &cards)
            let elapsed = started.duration(to: clock.now)
            samples.append(elapsed)
            #expect(began)
            #expect(cards.isEmpty)
            #expect(answers.request(group: request.group, id: request.id) == request)
        }
        let ordered = samples.sorted()
        print("WatchAnswers.begin pure-state feedback: \(iterations) isolated one-card iterations; "
              + "min=\(ordered[0]), median=\(ordered[iterations / 2]), max=\(ordered[iterations - 1]). "
              + "Diagnostic only, no latency threshold; excludes touch, rendering, haptics, network and end-to-end latency.")
    }

    @Test func feedbackRemovesTheCardBeforeNetworkCompletion() {
        var answers = WatchAnswers()
        var cards = [request]
        #expect(answers.begin(request, in: &cards))
        #expect(cards.isEmpty)
        #expect(answers.answering == [request.uid])
        #expect(!answers.begin(request, in: &cards))
        #expect(answers.reconcile([request]).isEmpty)
    }

    @Test func failureRestoresCardAndItsErrorWithoutDuplicatingIt() {
        var answers = WatchAnswers()
        var cards = [request]
        _ = answers.begin(request, in: &cards)
        answers.fail(request, message: "Unavailable", in: &cards)
        #expect(cards == [request])
        #expect(answers.errors[request.uid] == "Unavailable")
        #expect(answers.answering.isEmpty)
        answers.fail(request, message: "Unavailable", in: &cards)
        #expect(cards.count == 1)
        #expect(answers.begin(request, in: &cards))
        #expect(answers.errors.isEmpty)
    }

    @Test func completionSuppressesStaleCardsUntilTheServerAcknowledgesTheirAbsence() {
        var answers = WatchAnswers()
        var cards = [request]
        #expect(answers.begin(request, in: &cards))
        answers.complete(request)
        #expect(answers.answering.isEmpty)
        #expect(answers.errors.isEmpty)
        #expect(!answers.begin(request, in: &cards))
        #expect(answers.reconcile([request]).isEmpty)
        #expect(answers.reconcile([request]).isEmpty)
        #expect(answers.reconcile([]).isEmpty)
        cards = answers.reconcile([request])
        #expect(cards == [request])
        #expect(answers.begin(request, in: &cards))
    }

    @Test func sameIDsOnDifferentHubsRemainIndependent() {
        var other = request
        other.group = "other"
        var answers = WatchAnswers()
        var cards = [request, other]
        _ = answers.begin(request, in: &cards)
        #expect(cards == [other])
        answers.complete(request)
        #expect(answers.reconcile([request, other]) == [other])
    }

    @Test func pendingAnswerSurvivesAnEmptyRefreshAndRestoresItsOriginalCardOnFailure() {
        var answers = WatchAnswers()
        var cards = [request]
        #expect(answers.begin(request, in: &cards))
        cards = answers.reconcile([])
        #expect(cards.isEmpty)
        #expect(answers.answering == [request.uid])
        answers.fail(request, message: "Offline", in: &cards)
        #expect(cards == [request])
        #expect(answers.errors == [request.uid: "Offline"])
        #expect(answers.answering.isEmpty)
    }

    @Test func terminalCompletionAfterServerRemovalDoesNotRestoreAnErrorCard() {
        var answers = WatchAnswers()
        var cards = [request]
        #expect(answers.begin(request, in: &cards))
        cards = answers.reconcile([])
        answers.complete(request)
        answers.fail(request, message: "Late failure", in: &cards)
        #expect(cards.isEmpty)
        #expect(answers.answering.isEmpty)
        #expect(answers.errors.isEmpty)
        #expect(answers.reconcile([request]).isEmpty)
        #expect(!answers.begin(request, in: &cards))
    }

    @Test func failureDoesNotOverwriteANewerCopyAlreadyInTheList() {
        var answers = WatchAnswers()
        var cards = [request]
        #expect(answers.begin(request, in: &cards))
        var refreshed = request
        refreshed.reason = "Updated request"
        cards = [refreshed]
        answers.fail(request, message: "Offline", in: &cards)
        #expect(cards == [refreshed])
        #expect(answers.errors == [request.uid: "Offline"])
        #expect(answers.reconcile([refreshed]) == [refreshed])
        #expect(answers.reconcile([]).isEmpty)
        #expect(answers.errors.isEmpty)
    }

    @Test func concurrentAnswersOnDifferentHubsHaveIndependentFailureAndSuccess() {
        var other = request
        other.group = "other"
        var answers = WatchAnswers()
        var cards = [request, other]
        #expect(answers.begin(request, in: &cards))
        #expect(answers.begin(other, in: &cards))
        #expect(answers.answering == [request.uid, other.uid])
        #expect(cards.isEmpty)
        answers.complete(other)
        answers.fail(request, message: "Retry", in: &cards)
        #expect(cards == [request])
        #expect(answers.errors == [request.uid: "Retry"])
        #expect(answers.reconcile([request, other]) == [request])
        #expect(answers.begin(request, in: &cards))
        #expect(answers.errors.isEmpty)
        #expect(!answers.begin(other, in: &cards))
        answers.complete(request)
        #expect(answers.answering.isEmpty)
        #expect(answers.reconcile([request, other]).isEmpty)
    }
}
