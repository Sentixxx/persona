import SwiftUI
import WatchKit
import PersonaWire

struct WatchSessionView: View {
    @Environment(WatchModel.self) private var model
    @Environment(\.scenePhase) private var phase
    var session: Session
    @State private var reply = ""
    @State private var sending = false
    @State private var sendFailed = false
    @State private var messages: [WatchMessage] = []
    @State private var liveCards = WatchAssistantFeed()
    @State private var loadingCards = false
    /// The hub's channels, to say which a message came in from (asked once; nothing from a hub without them).
    @State private var channels: [HubChannel]?

    /// The session as the latest refresh has it (the one this page was opened with goes stale): its state follows, and
    /// a new rev (the transcript grew) reloads the messages.
    private var current: Session { model.sessions.first { $0.key == session.key } ?? session }

    /// What reloads the page: a new rev (or refresh) while the app is in front, and coming back to the front.
    private struct Reload: Hashable {
        var rev: Int64? = nil
        var tick: Date? = nil
        var active: Bool
    }

    var body: some View {
        let session = current
        let active = phase == .active
        ScrollView {
            VStack(alignment: .leading, spacing: Theme.Watch.blockSpacing) {
                Text(session.displayTitle).font(Theme.Font.heading).fixedSize(horizontal: false, vertical: true)
                HStack(spacing: Theme.Space.sm) {
                    Circle().fill(session.stateTone.dot).frame(width: Theme.Size.dotS, height: Theme.Size.dotS)
                    Text(session.stateLabel).font(Theme.Font.labelStrong).foregroundStyle(session.stateTone.text)
                }
                if let run = session.leadWorkflow { WatchWorkflowChip(run: run) }
                ForEach(liveCards.lines(messages).suffix(WatchMessage.limit)) { line in
                    switch line {
                    case .message(let it):
                    if let source = it.source {
                        WatchSourceMessage(message: it, source: source)
                    } else if let n = it.injected {
                        // Persona's message for the model (a task's notice, a scheduled run…): its line, centered, never
                        // its words (docs/protocol/protocol.md「Messages injected by Persona」).
                        Label { Text(n.line) } icon: { Theme.Icon.image(InjectedLook.icon(n)).foregroundStyle(InjectedLook.tint(n)) }
                            .font(Theme.Font.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(2)
                            .multilineTextAlignment(.center)
                            .frame(maxWidth: .infinity)
                    } else {
                        // A bubble as wide as its words, the user's on the right, set off from the other edge. What the
                        // user sent wears the phone's bubble (`Theme.userBubble`, #2647); another session's message
                        // (`from`) stays quiet like a reply.
                        let own = it.role == "user" && it.from == nil
                        Text(it.text)
                            .font(Theme.Font.caption)
                            .lineLimit(8)
                            .foregroundStyle(own ? Theme.userBubbleText : .primary)
                            .padding(Theme.Watch.bubblePadding)
                            .background(own ? Theme.userBubble : Theme.Fill.well, in: .rect(cornerRadius: Theme.Radius.control))
                            .padding(it.role == "user" ? .leading : .trailing, Theme.Space.l)
                            .frame(maxWidth: .infinity, alignment: it.role == "user" ? .trailing : .leading)
                        // Came in from a channel (WeChat, the Feishu bot…), as under the phone's bubble.
                        if it.fromCard {
                            Text("From a card").font(Theme.Font.caption).foregroundStyle(.secondary).lineLimit(1)
                                .frame(maxWidth: .infinity, alignment: .trailing)
                        }
                        if it.role == "user", let c = ChannelSource.of(it.clientMsgID, in: channels ?? []) {
                            Text("From \(c.name)").font(Theme.Font.caption).foregroundStyle(.secondary).lineLimit(1)
                                .frame(maxWidth: .infinity, alignment: .trailing)
                        }
                    }
                    case .view(let item):
                        Text(liveCards.fallback(item)).font(Theme.Font.body)
                            .padding(Theme.Watch.bubblePadding)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .accessibilityIdentifier("watch-assistant-view-fallback")
                    }
                }
                if let source = session.sourceSubtitle {
                    Text(source).font(Theme.Font.caption).foregroundStyle(.secondary)
                }
                WatchReplyInput(text: $reply, suggestions: [String(localized: "Continue"), String(localized: "Looks good"), String(localized: "Stop for now")])
                    .disabled(!session.canSend || sending)
                if sendFailed {
                    Text("Send failed. Draft kept.").font(Theme.Font.caption).foregroundStyle(Theme.danger)
                }
                Button {
                    guard current.canSend, !sending else { return }
                    let text = reply
                    guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
                    sending = true
                    sendFailed = false
                    Task {
                        defer { sending = false }
                        guard await model.send(session.key, text) else {
                            sendFailed = true
                            return
                        }
                        if reply == text { reply = "" }
                        await load()
                    }
                } label: {
                    if sending { ProgressView() }
                    else { Label { Text("Send").lineLimit(1) } icon: { Theme.Icon.image(Theme.Icon.send) } }
                }
                .buttonStyle(.borderedProminent)
                .disabled(!session.canSend || sending || reply.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                if session.status.isActive && session.canInterrupt {
                    Button { Task { await model.interrupt(session.key) } } label: {
                        Label { Text("Interrupt [Composer Buttons f9d193]").lineLimit(1) } icon: { Theme.Icon.image(Theme.Icon.interrupt) }
                    }
                    .tint(Theme.danger)
                }
            }
        }
        .watchSnapshotScroll()
        .navigationTitle("")
        .task {
            try? await model.api(session.group)?.post("/api/v1/sessions/\(session.machineID)/\(session.sessionID)/seen")
        }
        // Only while the app is in front: the phone's summaries reach the watch in the background too (while it
        // records), and reloading for each of them there ran into watchOS's background CPU limit (#6256).
        .task(id: Reload(rev: session.rev, active: active)) { if active { await load() } }
        // The model refreshes every 8 s while the app is active; a session without a rev (older hub) still reloads.
        .task(id: Reload(tick: session.rev == nil ? model.lastUpdate : nil, active: active)) {
            if active, session.rev == nil { await load() }
        }
        .task(id: Reload(tick: model.lastUpdate, active: active)) { if active, session.assistant { await loadCards() } }
    }

    private func loadCards() async {
        guard !loadingCards, current.assistant, let api = model.api(session.group) else { return }
        loadingCards = true
        defer { loadingCards = false }
        // Full view snapshots refresh even when no feed item or transcript revision was added.
        for _ in 0..<20 {
            let before = liveCards.cursor
            guard let response = try? await api.feed(conversation: session.sessionID, since: before),
                  !Task.isCancelled, model.api(session.group)?.config == api.config else { return }
            liveCards.receive(response, conversation: session.sessionID)
            guard response.items.count == 500, liveCards.cursor != before else { return }
        }
    }

    private func load() async {
        guard let api = model.api(session.group), let res = try? await api.items(session.key, beforeSeq: nil, turns: 2),
              !Task.isCancelled else { return }
        messages = WatchMessage.latest(res.items)
        if channels == nil, messages.contains(where: { $0.role == "user" && ChannelSource.possible($0.clientMsgID) }) {
            channels = (try? await api.channels()) ?? []
        }
    }
}

struct WatchReplyInput: View {
    @Binding var text: String
    var suggestions: [String]

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Watch.lineSpacing) {
            if !text.isEmpty {
                TextField("Reply", text: $text, axis: .vertical)
                    .font(Theme.Font.caption)
            }
            TextFieldLink(prompt: Text("Reply")) {
                Label { Text("Dictate").lineLimit(1) } icon: { Theme.Icon.image(Theme.Icon.dictate) }
            } onSubmit: { dictatedText in
                guard !dictatedText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
                text = text.isEmpty ? dictatedText : text + "\n" + dictatedText
            }
            .watchOpenGesture()
            if text.isEmpty {
                ForEach(suggestions, id: \.self) { suggestion in
                    Button { text = suggestion } label: {
                        Text(suggestion).font(Theme.Font.caption).lineLimit(1)
                    }
                }
            }
        }
    }
}
