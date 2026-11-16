#if DEBUG
import Foundation
import PersonaWire

enum WatchDashboardSamples {
    static func install(_ model: WatchModel) -> Bool {
        guard let state = UserDefaults.standard.string(forKey: "showWatchDashboard") else { return false }
        model.dashboardSample = true
        guard state != "unpaired" else { return true }
        model.configs = ["": ServerConfig(pairURL: "persona://pair?url=https://example.invalid&token=sample")!]
        model.lastUpdate = state == "stale" ? .now.addingTimeInterval(-300) : .now
        if state == "offline" { model.error = String(localized: "Can't reach the hub") }
        if state == "calm" { return true }
        if state == "partial" {
            model.configs["other"] = model.configs[""]
            model.names["other"] = "Second group"
            model.groupFailures = ["other"]
            return true
        }
        let sessionData = """
        [{"machine_id":"sample","session_id":"trip","title":"Plan a weekend trip","cwd":"","status":"idle","state":"needs_you","capabilities":{"approve":true,"send":true}},
         {"machine_id":"sample","session_id":"photos","title":"Organize photos","cwd":"","status":"working","state":"working","capabilities":{"send":true,"interrupt":true}},
         {"machine_id":"sample","session_id":"reading","title":"Reading list","cwd":"","status":"done","state":"unread"},
         {"machine_id":"sample","session_id":"move","title":"Move-out checklist","cwd":"","status":"idle","state":"needs_you","capabilities":{"approve":true,"send":true}},
         {"machine_id":"sample","session_id":"dinner","title":"Dinner booking","cwd":"","status":"idle","state":"needs_you","capabilities":{"approve":true,"send":true}}]
        """
        model.sessions = try! JSON.decoder.decode([Session].self, from: Data(sessionData.utf8))
        model.sessions[1].workflows = [WorkflowRun(taskID: "photos", agentsStarted: 4, agentsDone: 2)]
        var permission = Interaction(id: "permission", machineID: "sample", sessionID: "trip", sessionTitle: "Plan a weekend trip", kind: .permission)
        permission.summary = "Check Saturday trains"
        permission.reason = "Compare departure times and fares before booking."
        permission.createdAt = .now.addingTimeInterval(-120)
        var plan = Interaction(id: "plan", machineID: "sample", sessionID: "move", sessionTitle: "Move-out checklist", kind: .plan)
        plan.plan = "Move-out plan\nBook a moving van for Saturday morning.\nPack the kitchen first.\nSchedule the final cleaning.\nReturn the keys to the landlord.\nSave the checklist for review."
        var question = Interaction(id: "question", machineID: "sample", sessionID: "dinner", sessionTitle: "Dinner booking", kind: .question)
        question.questions = [Question(question: "Which time works?", header: nil, multiSelect: false,
            options: [QuestionOption(label: "7 pm (Recommended)"), QuestionOption(label: "8 pm")])]
        var screen = Interaction(id: "screen", machineID: "sample", sessionID: "dinner", sessionTitle: "Dinner booking", kind: .screen)
        screen.screen = "Choose an option:\n1. Continue\n2. Cancel"
        screen.dialog = try! JSON.decoder.decode(ScreenDialog.self, from: Data("""
        {"question":"Continue with this plan?","rev":"sample","options":[{"key":"1","label":"Continue"},{"key":"2","label":"Cancel"}]}
        """.utf8))
        var form = Interaction(id: "elicitation", machineID: "sample", sessionID: "dinner", sessionTitle: "Dinner booking", kind: .elicitation)
        form.summary = "More information is needed"
        model.interactions = [permission, plan, question, screen, form]
        if let kind = InteractionKind(rawValue: state) { model.interactions = model.interactions.filter { $0.kind == kind } }
        if state == "multiple" {
            question.questions?.append(Question(question: "Which activities?", header: nil, multiSelect: true,
                options: [QuestionOption(label: "Museum"), QuestionOption(label: "Park")]))
            model.interactions = [question]
        }
        model.inbox = try! JSON.decoder.decode([InboxItem].self, from: Data("""
        [{"id":"mail","source":"mail","kind":"mail","account":"sample","account_name":"Personal","title":"Weekend plans","sender":"A friend","preview":"Shall we meet on Saturday?","count":1,"triage":"action"}]
        """.utf8))
        return true
    }
}
#endif
