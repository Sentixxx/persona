import SwiftUI
import WatchKit
import PersonaWire

extension View {
    @ViewBuilder func watchSnapshotScroll() -> some View {
        #if DEBUG
        defaultScrollAnchor(UserDefaults.standard.bool(forKey: "watchScrollBottom") ? .bottom : .top)
        #else
        self
        #endif
    }
    @ViewBuilder func watchOpenGesture() -> some View {
        if #available(watchOS 11.0, *) { handGestureShortcut(.primaryAction) }
        else { self }
    }
    /// A row of the watch's lists as a card (`Theme.Watch`): its own rounded background with a gap to the next card,
    /// padding inside, at least 44 pt tall, so a 1-line and a 3-line row have the same margins.
    func watchCard() -> some View {
        let p = Theme.Watch.cardPadding, half = max(0, Theme.Watch.cardGap - Theme.Watch.listRowSpacing) / 2
        return frame(maxWidth: .infinity, minHeight: Theme.Watch.minRowHeight - p.top - p.bottom, alignment: .leading)
            .listRowInsets(EdgeInsets(top: p.top + half, leading: p.leading, bottom: p.bottom + half, trailing: p.trailing))
            .listRowBackground(
                RoundedRectangle(cornerRadius: Theme.Watch.cardRadius, style: .continuous)
                    .fill(Theme.Watch.cardFill)
                    .padding(.vertical, half)
            )
    }
}

extension InteractionKind {
    var watchTitle: String {
        switch self {
        case .question: String(localized: "Question [Tool Views 387441]")
        case .plan: String(localized: "Plan Approval")
        case .permission: String(localized: "Permission")
        case .screen: String(localized: "Terminal")
        case .elicitation: String(localized: "MCP Request")
        }
    }

    var watchSymbol: String {
        switch self {
        case .question: Theme.Icon.question
        case .plan: Theme.Icon.plan
        case .permission: Theme.Icon.askFirst
        case .screen: Theme.Icon.terminal
        case .elicitation: Theme.Icon.mcpForm
        }
    }
}

extension Interaction {
    var watchSummary: String {
        switch kind {
        case .question: questions?.first?.question ?? ""
        case .plan: (plan ?? "").split(separator: "\n").first.map { $0.trimmingCharacters(in: CharacterSet(charactersIn: "# ")) } ?? String(localized: "Plan [Interaction Text 2619dd]")
        case .permission:
            // The password card: its summary names the computer and every command; `secret_run` means nothing here.
            (isSecretRun ? [summary] : [toolName, summary]).compactMap { $0 }
                .joined(separator: String(localized: ": ", comment: "Separator between a label and its value"))
        case .screen: String(localized: "A dialog is open in the terminal")
        case .elicitation: askLine(includeToolName: false) ?? ""
        }
    }
}
