import Foundation
import Testing
@testable import Persona
import PersonaWire

struct WatchDashboardTests {
    private func session(_ id: String, state: String = "idle", group: String = "",
                         extra: [String: Any] = [:]) throws -> Session {
        var fields: [String: Any] = ["machine_id": "machine", "session_id": id, "title": id,
                                     "cwd": "/code", "status": "idle", "state": state]
        fields.merge(extra) { _, new in new }
        var value = try JSON.decoder.decode(Session.self, from: JSONSerialization.data(withJSONObject: fields))
        value.group = group
        return value
    }

    private func request(_ id: String, session: String = "session", kind: InteractionKind = .question,
                         age: Double? = 0, group: String = "") -> Interaction {
        var value = Interaction(id: id, machineID: "machine", sessionID: session, kind: kind,
                                createdAt: age.map { Date(timeIntervalSince1970: $0) })
        value.group = group
        return value
    }

    private func inbox(_ id: String, extra: [String: Any] = [:]) throws -> InboxItem {
        var fields: [String: Any] = ["id": id, "source": "mail", "kind": "mail", "account": "account",
                                     "account_name": "Mail", "title": id, "preview": "Message", "count": 1]
        fields.merge(extra) { _, new in new }
        return try JSON.decoder.decode(InboxItem.self, from: JSONSerialization.data(withJSONObject: fields))
    }

    @Test func emptyDashboardHasNoWorkOrRequests() {
        let dashboard = WatchDashboard(sessions: [], interactions: [])
        #expect(dashboard.needsYou == 0 && dashboard.approvals == 0 && dashboard.questions == 0)
        #expect(dashboard.messages == 0 && dashboard.working == 0 && dashboard.unread == 0)
        #expect(dashboard.backgroundWaiting == 0)
        #expect(dashboard.nextUp == nil && dashboard.nextUpBlockedReason == nil)
        #expect(dashboard.queue.isEmpty && dashboard.running.isEmpty)
    }

    @Test func needsYouMatchesThePetAndCountsDistinctSessionsAcrossHubs() throws {
        let waiting = try session("waiting", state: "needs_you")
        let sessions = [try session("session", state: "working"), waiting, waiting,
                        try session("session", state: "needs_you", group: "other")]
        let requests = [request("permission", kind: .permission), request("plan", kind: .plan),
                        request("question", group: "other"), request("missing", session: "missing"),
                        request("sessionless", session: "")]
        let dashboard = WatchDashboard(sessions: sessions, interactions: requests)
        let pet = WatchPet.status(sessions: sessions, interactions: requests,
                                  unreachable: false, partlyUnreachable: false)
        #expect(pet.state == .needsYou)
        #expect(dashboard.needsYou == 5 && dashboard.needsYou == pet.count)
        #expect(dashboard.queue.count == dashboard.needsYou)
        #expect(dashboard.approvals == 2 && dashboard.questions == 3)
        #expect(dashboard.queue.contains { $0.id == waiting.key && $0.interactions.isEmpty })
    }

    @Test func kindCountsCountRequestsRatherThanSessions() throws {
        let requests = [request("permission", kind: .permission), request("plan", kind: .plan),
                        request("question"), request("screen", kind: .screen), request("form", kind: .elicitation)]
        let dashboard = WatchDashboard(sessions: [try session("session")], interactions: requests)
        #expect(dashboard.needsYou == 1)
        #expect(dashboard.approvals == 2 && dashboard.questions == 2)
        #expect(dashboard.queue.first?.interactions.count == 5)
    }

    @Test func messagesIncludeReadActionsButExcludeDoneAndOtherTriage() throws {
        let items = try [inbox("legacy"), inbox("read", extra: ["status": "action", "read": true]),
                         inbox("tier", extra: ["tier": "action"]),
                         inbox("done", extra: ["status": "action", "done_at": "2026-11-16T00:00:00Z"]),
                         inbox("fyi", extra: ["tier": "fyi"]), inbox("noise", extra: ["status": "noise"]),
                         inbox("working", extra: ["status": "working", "tier": "action"])]
        let dashboard = WatchDashboard(sessions: [], interactions: [], inbox: items)
        #expect(dashboard.messages == 3)
        #expect(dashboard.needsYou == 0 && dashboard.nextUp == nil)
    }

    @Test func nextUpUsesKindPriorityThenOldestRequest() throws {
        let sessions = [try session("session")]
        var requests = [request("screen", kind: .screen, age: 0), request("question", age: 1),
                        request("plan", kind: .plan, age: 2), request("new-permission", kind: .permission, age: 4),
                        request("old-permission", kind: .permission, age: 3)]
        for expected in ["old-permission", "new-permission", "plan", "question", "screen"] {
            let dashboard = WatchDashboard(sessions: sessions, interactions: requests)
            #expect(dashboard.nextUp?.id == expected)
            #expect(dashboard.nextUpBlockedReason == nil)
            requests.removeAll { $0.id == expected }
        }
    }

    @Test func answerableRequestsComeBeforeOlderBlockedPermissions() throws {
        let requests = [request("blocked", session: "missing", kind: .permission, age: 0), request("answer", age: 1)]
        let dashboard = WatchDashboard(sessions: [try session("session")], interactions: requests)
        #expect(dashboard.nextUp?.id == "answer")
        #expect(dashboard.nextUpBlockedReason == nil)
    }

    @Test func blockedFallbackUsesAgeInsteadOfKindPriority() throws {
        let requests = [request("permission", kind: .permission, age: 2), request("question", age: 1)]
        let dashboard = WatchDashboard(sessions: [], interactions: requests)
        #expect(dashboard.nextUp?.id == "question")
        #expect(dashboard.nextUpBlockedReason == .missingSession)
    }

    @Test func blockedReasonsPreserveSessionCapabilities() throws {
        let attached = try session("session", extra: ["source_kind": "codex", "capabilities": ["attach": true]])
        let computer = try session("session", extra: ["capabilities": ["approve": false]])
        #expect(WatchDashboard(sessions: [attached], interactions: [request("attach")]).nextUpBlockedReason == .attach)
        #expect(WatchDashboard(sessions: [computer], interactions: [request("computer")]).nextUpBlockedReason == .computer)
    }

    @Test func sessionlessAndFoldedRequestsKeepSharedAnswerability() {
        var folded = request("folded", session: "child")
        folded.foldedUnder = "parent"
        for interaction in [folded, request("sessionless", session: "")] {
            let dashboard = WatchDashboard(sessions: [], interactions: [interaction])
            #expect(dashboard.nextUp == interaction && dashboard.nextUpBlockedReason == nil)
        }
    }

    @Test func formsSecretsAndFieldsNeverDisplaceAnAnswerableRequest() throws {
        let sessions = [try session("session")]
        var secretRun = request("secret-run", kind: .permission)
        secretRun.toolName = "secret_run"
        var handoff = request("handoff", kind: .permission)
        handoff.toolName = "secret_handoff"
        var password = request("password", kind: .screen)
        password.secret = true
        var fields = request("fields", kind: .permission)
        fields.fields = [InteractionField(key: "value", label: "Value")]
        for blocked in [secretRun, handoff, password, fields, request("form", kind: .elicitation)] {
            let alone = WatchDashboard(sessions: sessions, interactions: [blocked])
            #expect(alone.nextUpBlockedReason == .requiresInput)
            let dashboard = WatchDashboard(sessions: sessions, interactions: [blocked, request("answer", age: 10)])
            #expect(dashboard.nextUp?.id == "answer" && dashboard.nextUpBlockedReason == nil)
        }
    }

    @Test func queueAndNextUpHaveStableOldestFirstOrdering() throws {
        let sessions = [try session("session"), try session("other")]
        let requests = [request("new", age: 3), request("tie-b", session: "other", age: 1),
                        request("tie-a", age: 1), request("unknown", age: nil)]
        let dashboard = WatchDashboard(sessions: sessions, interactions: requests)
        #expect(dashboard.nextUp?.id == "unknown")
        #expect(dashboard.queue.map(\.id.sessionID) == ["session", "other"])
        #expect(dashboard.queue.first?.interactions.map(\.id) == ["unknown", "tie-a", "new"])
        #expect(dashboard == WatchDashboard(sessions: sessions.reversed(), interactions: requests.reversed()))
    }

    @Test func runningIncludesBackgroundWaitingAndUnseenButNotIdleOrNeedsYou() throws {
        let waiting = try session("background", state: "working", extra: ["background_waiting": true])
        let sessions = [try session("unseen", state: "unread"), try session("session", state: "working"),
                        waiting, waiting, try session("idle"), try session("needs-you", state: "needs_you")]
        let dashboard = WatchDashboard(sessions: sessions, interactions: [])
        #expect(dashboard.working == 2 && dashboard.backgroundWaiting == 1 && dashboard.unread == 1)
        #expect(dashboard.running.map(\.id.sessionID) == ["background", "session", "unseen"])
        #expect(dashboard.running.allSatisfy { $0.progress == nil })
    }

    @Test func workflowProgressMatchesFleetReportedCountsAndLeadOrder() throws {
        var value = try session("workflow", state: "working")
        value.workflows = [WorkflowRun(taskID: "ended", status: "completed", running: false, agentsStarted: 10, agentsDone: 10),
                           WorkflowRun(taskID: "lead", agentsStarted: 185, agentsDone: 169),
                           WorkflowRun(taskID: "older", agentsStarted: 4, agentsDone: 1)]
        let row = try #require(WatchDashboard(sessions: [value], interactions: []).running.first)
        #expect(row.workflow?.id == "lead")
        let fleet = FleetState.Item.Progress(done: 169, started: 185)
        #expect(row.progress?.done == fleet.done && row.progress?.started == fleet.started)
    }

    @Test func workflowProgressUsesFreshSummaryAndClampsLikeFleet() throws {
        var value = try session("workflow", state: "working")
        value.workflows = [WorkflowRun(taskID: "retained", agentsStarted: 185, agentsDone: 169)]
        value.listWaiting = false
        for (done, expected) in [(-2, 0), (2, 2), (9, 4)] {
            value.listWorkflowProgress = WorkflowRun(taskID: "fresh", agentsStarted: 4, agentsDone: done)
            let row = try #require(WatchDashboard(sessions: [value], interactions: []).running.first)
            #expect(row.workflow?.id == "fresh")
            #expect(row.progress == WatchDashboard.Progress(done: expected, started: 4))
        }
        for started in [nil, 0, -1] as [Int?] {
            value.listWorkflowProgress = WorkflowRun(taskID: "fresh", agentsStarted: started, agentsDone: 1)
            #expect(WatchDashboard(sessions: [value], interactions: []).running.first?.progress == nil)
        }
        value.listWorkflowProgress = nil
        #expect(WatchDashboard(sessions: [value], interactions: []).running.first?.workflow == nil)
    }

    @Test func collidingSessionIDsOnDifferentMachinesAndHubsCountSeparately() throws {
        let local = try session("session", state: "working")
        let remote = try session("session", state: "unread", group: "other")
        let anotherMachine = try session("session", state: "needs_you", extra: ["machine_id": "another-machine"])
        var machineRequest = request("request", kind: .permission)
        machineRequest.machineID = "another-machine"
        let requests = [request("request", kind: .permission), request("request", group: "other"), machineRequest]
        let dashboard = WatchDashboard(sessions: [local, remote, anotherMachine, local], interactions: requests)
        #expect(dashboard.needsYou == 3)
        #expect(dashboard.approvals == 2)
        #expect(dashboard.questions == 1)
        #expect(Set(dashboard.queue.map(\.id)) == [local.key, remote.key, anotherMachine.key])
        #expect(dashboard.queue.allSatisfy { $0.interactions.count == 1 })
        #expect(dashboard.working == 1 && dashboard.unread == 1)
        #expect(Set(dashboard.running.map(\.id)) == [local.key, remote.key])
    }

    @Test func answerabilityNeverBorrowsAnotherHubsSessionCapabilities() throws {
        let local = try session("session")
        let remote = try session("session", group: "other", extra: ["capabilities": ["approve": false]])
        let blocked = request("permission", kind: .permission, group: "other")
        let answerable = request("question", age: 1)
        let dashboard = WatchDashboard(sessions: [local, remote], interactions: [blocked, answerable])
        #expect(dashboard.nextUp == answerable)
        #expect(dashboard.nextUpBlockedReason == nil)
        #expect(WatchDashboard(sessions: [local, remote], interactions: [blocked]).nextUpBlockedReason == .computer)
        #expect(WatchDashboard(sessions: [local], interactions: [blocked]).nextUpBlockedReason == .missingSession)
        #expect(dashboard.queue.first { $0.id == remote.key }?.session == remote)
    }

    @Test func messageCountCountsActionItemsNotTheirBundledMessageTotals() throws {
        let items = try [inbox("thread", extra: ["status": "action", "count": 25]),
                         inbox("single", extra: ["status": "action", "count": 1]),
                         inbox("read-only", extra: ["tier": "fyi", "count": 50])]
        let dashboard = WatchDashboard(sessions: [], interactions: [], inbox: items)
        #expect(dashboard.messages == 2)
        #expect(dashboard.needsYou == 0)
        #expect(dashboard.approvals == 0 && dashboard.questions == 0)
    }

    @Test func workflowWithStartedAgentsAndNoDoneCountShowsZeroCompleted() throws {
        var value = try session("workflow", state: "working")
        value.workflows = [WorkflowRun(taskID: "lead", agentsStarted: 4)]
        let row = try #require(WatchDashboard(sessions: [value], interactions: []).running.first)
        #expect(row.progress == WatchDashboard.Progress(done: 0, started: 4))
    }
}
