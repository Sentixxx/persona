import SwiftUI
import WatchKit
import PersonaWire

struct WatchInboxRow: View {
    var item: InboxItem

    private var source: String {
        if item.isLark { return item.kindLabel ?? String(localized: "Lark [Inbox Event Views 7e4419]") }
        if item.connector != nil { return WatchInboxText.connectorSource(item) }
        return String(localized: "Mail [Assistant View 3d708e]")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Watch.lineSpacing) {
            Label {
                Text(source).lineLimit(1)
            } icon: {
                if item.isLark { Image(Theme.Brand.lark).resizable().scaledToFit().frame(width: Theme.Size.markS, height: Theme.Size.markS) }
                else if item.connector != nil { Theme.Icon.image(Theme.Icon.inbox) }
                else { Theme.Icon.image(Theme.Icon.mailFilled) }
            }
                .font(Theme.Font.captionStrong)
                .foregroundStyle(item.kind == "mention" ? StatusPalette.needsYou.text : Theme.accent)
            Text(item.title).font(Theme.Font.heading).lineLimit(2)
            Text(item.summary?.isEmpty == false ? item.summary! : item.preview).font(Theme.Font.caption).foregroundStyle(.secondary).lineLimit(3)
        }
    }
}

/// An inbox item on the wrist: the summary and the latest message; AI Reply drafts a reply to read and send,
/// Done files it. A connector's item is read-only here (its reply goes through its own thread on the phone).
struct WatchInboxItemView: View {
    @Environment(WatchModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    var item: InboxItem
    @State private var draft: String?
    @State private var drafting = false
    @State private var sending = false
    @State private var sendFailed = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Theme.Watch.blockSpacing) {
                if let s = item.summary, !s.isEmpty {
                    Text(s).font(Theme.Font.heading)
                }
                Text([item.sender, item.preview].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: String(localized: ": ", comment: "Separator between a label and its value")))
                    .font(Theme.Font.caption).foregroundStyle(.secondary)
                if item.connector != nil {
                    Text("Reply on Your iPhone").font(Theme.Font.caption).foregroundStyle(.tertiary)
                } else {
                    WatchReplyInput(
                        text: Binding(get: { draft ?? "" }, set: { draft = $0 }),
                        suggestions: [String(localized: "Thanks!"), String(localized: "Got it.")]
                    )
                    .disabled(drafting || sending)
                    if sendFailed {
                        Text("Send failed. Draft kept.").font(Theme.Font.caption).foregroundStyle(Theme.danger)
                    }
                    if let draft, !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        Button {
                            guard !sending else { return }
                            sending = true
                            sendFailed = false
                            Task {
                                defer { sending = false }
                                if await model.reply(item, draft) { dismiss() }
                                else { sendFailed = true }
                            }
                        } label: {
                            if sending { ProgressView() } else { Text("Send").lineLimit(1) }
                        }
                        .buttonStyle(.borderedProminent)
                        .disabled(sending || drafting)
                    } else {
                        Button {
                            guard !drafting, !sending else { return }
                            drafting = true
                            Task {
                                draft = try? await model.api?.inboxDraft(item.id)
                                drafting = false
                                if draft == nil { WKInterfaceDevice.current().play(.failure) }
                            }
                        } label: {
                            if drafting { ProgressView() }
                            else { Label { Text("AI Reply").lineLimit(1) } icon: { Theme.Icon.image(Theme.Icon.ai) } }
                        }
                        .buttonStyle(.borderedProminent)
                        .disabled(drafting || sending)
                    }
                }
                Button {
                    Task {
                        await model.setDone(item)
                        dismiss()
                    }
                } label: {
                    Label { Text("Done [Inbox View 59f6c8]").lineLimit(1) } icon: { Theme.Icon.image(Theme.Icon.done) }
                }
                .disabled(drafting || sending)
            }
        }
        .watchSnapshotScroll()
        .navigationTitle(item.title)
        .onAppear { if draft == nil { draft = item.agentDraft } } // the AI twin's, ready to send
    }
}
