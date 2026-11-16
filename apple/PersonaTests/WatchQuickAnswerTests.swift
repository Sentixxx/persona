import Foundation
import Testing
@testable import Persona

struct WatchQuickAnswerTests {
    @Test func planRevisionSharesFeedbackAcrossVisibleAndSwipeActions() {
        #expect(WatchQuickAnswer.negativeResolution(for: .plan) == Resolution(
            approve: false, feedback: String(localized: "Please reconsider this plan.")))
        #expect(WatchQuickAnswer.negativeResolution(for: .permission) == Resolution(allow: false))
    }

    @Test func formSummaryPrefersRequestMessageThenSummary() {
        var request = Interaction(id: "form", machineID: "machine", sessionID: "session", kind: .elicitation)
        request.summary = "  More information is needed  "
        #expect(WatchQuickAnswer.formSummary(request) == "More information is needed")
        request.elicitation = ElicitationRequest(mode: "form", message: " Choose a destination ")
        #expect(WatchQuickAnswer.formSummary(request) == "Choose a destination")
        request.elicitation?.message = " \n "
        #expect(WatchQuickAnswer.formSummary(request) == "More information is needed")
    }

    @Test(arguments: [nil, "", " \n "] as [String?])
    func emptyFormSummaryFallsBackToLocalizedTitle(summary: String?) {
        var request = Interaction(id: "form", machineID: "machine", sessionID: "session", kind: .elicitation)
        request.summary = summary
        #expect(WatchQuickAnswer.formSummary(request) == String(localized: "MCP Request"))
    }

    private func question(_ text: String = "Choose a destination", multiSelect: Bool = false,
                          labels: [String] = ["Preview (Recommended)", "Production"]) -> Question {
        Question(question: text, header: "Destination", multiSelect: multiSelect,
                 options: labels.map { QuestionOption(label: $0) })
    }

    private func interaction(_ questions: [Question]?) -> Interaction {
        var request = Interaction(id: "request", machineID: "machine", sessionID: "session", kind: .question)
        request.questions = questions
        return request
    }

    @Test(arguments: [1, 4])
    func singleChoiceAtQuickAnswerBoundariesKeepsOriginalLabels(count: Int) {
        let question = question(labels: Array(["Preview (Recommended)", "Production", "Local", "Other"].prefix(count)))
        let request = interaction([question])
        #expect(!WatchQuickAnswer.requiresPhone(request))
        #expect(WatchQuickAnswer.simpleQuestion(request) == question)
    }

    @Test(arguments: [0, 5])
    func emptyOrOversizedOptionsRequireTheDetailForm(count: Int) {
        let request = interaction([question(labels: (0..<count).map { "Option \($0)" })])
        #expect(!WatchQuickAnswer.requiresPhone(request))
        #expect(WatchQuickAnswer.simpleQuestion(request) == nil)
    }

    @Test func multipleQuestionsAndMultiSelectAreNotOneTapAnswers() {
        let requests = [interaction([question(multiSelect: true)]),
                        interaction([question(), question("Choose a platform")]),
                        interaction([]), interaction(nil)]
        for request in requests {
            #expect(!WatchQuickAnswer.requiresPhone(request))
            #expect(WatchQuickAnswer.simpleQuestion(request) == nil)
        }
    }

    @Test(arguments: [InteractionKind.permission, .plan, .screen, .elicitation])
    func questionPayloadOnAnotherKindDoesNotEnableQuickChoices(kind: InteractionKind) {
        var request = interaction([question()])
        request.kind = kind
        #expect(WatchQuickAnswer.simpleQuestion(request) == nil)
    }

    @Test func sensitiveOrStructuredInputAlwaysRequiresThePhone() {
        let ordinary = interaction([question()])
        var secret = ordinary
        secret.secret = true
        var fields = ordinary
        fields.fields = [InteractionField(key: "value", label: "Value")]
        var secretRun = ordinary
        secretRun.kind = .permission
        secretRun.toolName = "secret_run"
        var handoff = ordinary
        handoff.kind = .permission
        handoff.toolName = "secret_handoff"
        var elicitation = ordinary
        elicitation.kind = .elicitation
        for request in [secret, fields, secretRun, handoff, elicitation] {
            #expect(WatchQuickAnswer.requiresPhone(request))
            #expect(WatchQuickAnswer.simpleQuestion(request) == nil)
        }
    }

    @Test func explicitlyNonsecretQuestionsWithEmptyFieldsRemainQuickAnswerable() {
        var request = interaction([question()])
        request.secret = false
        request.fields = []
        #expect(!WatchQuickAnswer.requiresPhone(request))
        #expect(WatchQuickAnswer.simpleQuestion(request) == question())
    }

    @Test func answersRequireAValidSelectionForEveryQuestion() {
        let destination = question()
        let platform = question("Choose a platform", multiSelect: true, labels: ["Phone", "Watch"])
        let questions = [destination, platform]
        #expect(WatchQuickAnswer.answers([], picks: [:]) == nil)
        #expect(WatchQuickAnswer.answers(questions, picks: [:]) == nil)
        #expect(WatchQuickAnswer.answers(questions, picks: [destination.question: ["Production"]]) == nil)
        #expect(WatchQuickAnswer.answers(questions, picks: [destination.question: ["Production"],
                                                           platform.question: []]) == nil)
        #expect(WatchQuickAnswer.answers(questions, picks: [destination.question: ["Production"],
                                                           platform.question: ["Removed option"]]) == nil)
    }

    @Test func answersPreserveWireLabelsAndOptionOrderAcrossQuestionTypes() {
        let destination = question()
        let platform = question("Choose a platform", multiSelect: true, labels: ["Phone", "Watch", "Tablet"])
        let picks: [String: Set<String>] = [destination.question: ["Preview (Recommended)"],
                                          platform.question: ["Tablet", "Phone", "Removed option"],
                                          "Removed question": ["Old answer"]]
        #expect(WatchQuickAnswer.answers([destination, platform], picks: picks) == [
            destination.question: "Preview (Recommended)", platform.question: "Phone, Tablet",
        ])
    }

    @Test func multiSelectCanSubmitOneOptionButEmptyOptionsCannotBeAnswered() {
        let platform = question(multiSelect: true, labels: ["Phone", "Watch"])
        #expect(WatchQuickAnswer.answers([platform], picks: [platform.question: ["Watch"]]) == [platform.question: "Watch"])
        let empty = question(labels: [])
        #expect(WatchQuickAnswer.answers([empty], picks: [empty.question: ["Stale option"]]) == nil)
    }

    @Test func singleSelectRejectsMultipleValidPicksInsteadOfJoiningThem() {
        let destination = question()
        let picks: [String: Set<String>] = [destination.question: ["Preview (Recommended)", "Production"]]
        #expect(WatchQuickAnswer.answers([destination], picks: picks) == nil)
        var multiSelect = destination
        multiSelect.multiSelect = true
        #expect(WatchQuickAnswer.answers([multiSelect], picks: picks) == [
            destination.question: "Preview (Recommended), Production",
        ])
    }

    @Test func anInvalidSingleSelectionRejectsTheWholeMultiQuestionSubmission() {
        let destination = question()
        let platform = question("Choose a platform", multiSelect: true, labels: ["Phone", "Watch"])
        let picks: [String: Set<String>] = [destination.question: ["Preview (Recommended)", "Production"],
                                          platform.question: ["Phone", "Watch"]]
        #expect(WatchQuickAnswer.answers([destination, platform], picks: picks) == nil)
    }
}
