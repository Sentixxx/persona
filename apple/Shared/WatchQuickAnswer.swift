import Foundation

nonisolated enum WatchQuickAnswer {
    static func negativeResolution(for kind: InteractionKind) -> Resolution {
        switch kind {
        case .permission: Resolution(allow: false)
        case .plan: Resolution(approve: false, feedback: String(localized: "Please reconsider this plan."))
        default: preconditionFailure("Only permission and plan requests have a negative decision")
        }
    }

    static func formSummary(_ interaction: Interaction) -> String {
        for candidate in [interaction.askLine(includeToolName: false), interaction.summary] {
            if let text = candidate?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty {
                return text
            }
        }
        return String(localized: "MCP Request")
    }

    static func requiresPhone(_ interaction: Interaction) -> Bool {
        interaction.requiresInput || interaction.secret == true
    }

    static func simpleQuestion(_ interaction: Interaction) -> Question? {
        guard !requiresPhone(interaction), interaction.kind == .question,
              let questions = interaction.questions, questions.count == 1,
              let question = questions.first, !question.multiSelect,
              !question.options.isEmpty, question.options.count <= 4 else { return nil }
        return question
    }

    static func answers(_ questions: [Question], picks: [String: Set<String>]) -> [String: String]? {
        guard !questions.isEmpty else { return nil }
        var answers: [String: String] = [:]
        for question in questions {
            let selected = question.options.map(\.label).filter { picks[question.question, default: []].contains($0) }
            guard !selected.isEmpty, question.multiSelect || selected.count == 1 else { return nil }
            answers[question.question] = selected.joined(separator: ", ")
        }
        return answers
    }
}
