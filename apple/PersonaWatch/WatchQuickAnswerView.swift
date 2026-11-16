import SwiftUI
import PersonaWire

struct WatchQuickAnswerView: View {
    @Environment(WatchModel.self) private var model
    var interaction: Interaction
    @State private var submitting = false

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Watch.blockSpacing) {
            if WatchQuickAnswer.requiresPhone(interaction) {
                WatchPhoneAnswerNotice()
            } else if model.canAnswer(interaction) {
                switch interaction.kind {
                case .permission, .plan:
                    WatchDecisionControl(kind: interaction.kind, shape: .capsule, resolve: act)
                        .disabled(submitting || model.answering.contains(interaction.uid))
                case .question:
                    if let question = WatchQuickAnswer.simpleQuestion(interaction) {
                        ForEach(question.options, id: \.label) { option in
                            Button {
                                act(Resolution(answers: [question.question: option.label]))
                            } label: {
                                WatchAnswerOptionLabel(option: option)
                            }
                            .disabled(submitting || model.answering.contains(interaction.uid))
                        }
                    } else { detailLink }
                case .screen, .elicitation:
                    detailLink
                }
            } else { detailLink }
            if let error = model.answerErrors[interaction.uid] {
                Text(error).font(Theme.Font.caption).foregroundStyle(Theme.cautionText)
            }
        }
        .buttonStyle(.bordered)
    }

    private var detailLink: some View {
        NavigationLink {
            WatchInteractionView(interaction: interaction)
        } label: {
            Label("Open request", systemImage: interaction.kind.watchSymbol)
                .font(Theme.Font.body)
                .frame(maxWidth: .infinity, minHeight: Theme.Watch.minRowHeight, alignment: .leading)
        }
    }

    private func act(_ resolution: Resolution) {
        guard !submitting, !model.answering.contains(interaction.uid),
              !WatchQuickAnswer.requiresPhone(interaction), model.canAnswer(interaction) else { return }
        submitting = true
        Task {
            await model.resolve(interaction, resolution)
            submitting = false
        }
    }
}

struct WatchAnswerOptionLabel: View {
    var option: QuestionOption
    var selected = false
    @State private var display: String?
    @State private var recommended = false

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Watch.lineSpacing) {
            HStack(spacing: Theme.Space.sm) {
                Text(display ?? option.label).font(Theme.Font.body)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: Theme.Space.flush)
                if selected { Theme.Icon.image(Theme.Icon.done).foregroundStyle(Theme.accent) }
            }
            if recommended {
                Text(LocalizedStringResource("watch.recommended", defaultValue: "Pick", comment: "Tag on the recommended answer, beside it on one watch button: as short as possible"))
                    .font(Theme.Font.captionStrong).foregroundStyle(Theme.ai)
                    .padding(.horizontal, Theme.Space.sm).padding(.vertical, Theme.Space.xxs)
                    .background(Theme.aiTint, in: .capsule)
            }
            if let detail = option.description, !detail.isEmpty {
                Text(detail).font(Theme.Font.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(maxWidth: .infinity, minHeight: Theme.Watch.minRowHeight, alignment: .leading)
        .multilineTextAlignment(.leading)
        .task(id: option.label) {
            let presentation = QuestionOption.display(option.label)
            display = presentation.0
            recommended = presentation.1
        }
    }
}

struct WatchPhoneAnswerNotice: View {
    var body: some View {
        Label("Open on iPhone", systemImage: Theme.Icon.phone).font(Theme.Font.body)
        Text("This request needs input on your iPhone or computer.")
            .font(Theme.Font.caption).foregroundStyle(.secondary)
    }
}

struct WatchExpandableText: View {
    var text: String
    var font = Theme.Font.body
    @State private var expanded = false
    @State private var collapsedHeight: CGFloat = 0
    @State private var fullHeight: CGFloat = 0

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Watch.lineSpacing) {
            Text(text).font(font).lineLimit(expanded ? nil : 8)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(alignment: .topLeading) {
                    VStack(spacing: Theme.Space.flush) {
                        Text(text).font(font).lineLimit(8)
                            .fixedSize(horizontal: false, vertical: true)
                            .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { collapsedHeight = $0 }
                        Text(text).font(font)
                            .fixedSize(horizontal: false, vertical: true)
                            .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { fullHeight = $0 }
                    }
                    .hidden()
                    .accessibilityHidden(true)
                }
            if expanded || fullHeight > collapsedHeight {
                Button { expanded.toggle() } label: {
                    if expanded { Text("Show less") } else { Text("Show all") }
                }
                .font(Theme.Font.caption)
            }
        }
        .onChange(of: text) { expanded = false }
    }
}
