import SwiftUI
import WatchKit
import PersonaWire

struct WatchInteractionView: View {
    @Environment(WatchModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @Environment(\.dynamicTypeSize) private var textSize
    var interaction: Interaction
    @State private var picks: [String: Set<String>] = [:]
    @State private var questionIndex = 0
    @State private var triedEarly = false
    @State private var submitting = false
    @State private var showScreen = false
    @State private var planText = ""
    @State private var terminalOptions: [ScreenDialog.Option] = []
    @State private var terminalPicks: Set<String> = []

    private var questions: [Question] { interaction.questions ?? [] }
    private var canAct: Bool {
        !WatchQuickAnswer.requiresPhone(interaction) && model.canAnswer(interaction)
            && !submitting && !model.answering.contains(interaction.uid)
    }

    private var blockedReason: String? {
        guard !model.canAnswer(interaction) else { return nil }
        guard let session = model.sessions.first(where: { $0.key == interaction.sessionKey }) else {
            return String(localized: "This session isn't on the watch. Handle it on your iPhone or computer.")
        }
        return session.canAttach
            ? String(localized: "Attach live on your iPhone first, or handle it on the computer.")
            : String(localized: "This session can't be approved on the watch. Handle it on the computer.")
    }

    /// Permission and plan requests end in a decision. At standard text sizes it stays under the scrolling text, never
    /// over it; at accessibility sizes it scrolls with the text.
    private var decides: Bool {
        (interaction.kind == .permission || interaction.kind == .plan)
            && !WatchQuickAnswer.requiresPhone(interaction) && model.canAnswer(interaction)
    }

    /// Several questions, or one with several picks, page with Previous / Next / Submit, kept under the text like a
    /// decision.
    private var pages: Bool {
        interaction.kind == .question && !WatchQuickAnswer.requiresPhone(interaction)
            && (questions.count > 1 || questions.first?.multiSelect == true)
    }

    var body: some View {
        Group {
            if (decides || pages) && !textSize.isAccessibilitySize {
                VStack(spacing: Theme.Space.s) {
                    page.watchBottomFade()
                    if decides {
                        WatchDecisionControl(kind: interaction.kind, shape: .ring, resolve: act).disabled(!canAct)
                    } else {
                        HStack(spacing: Theme.Space.sm) { questionNavigation }.font(Theme.Font.captionStrong)
                    }
                }
                .padding(.bottom, Theme.Space.s)
                .ignoresSafeArea(.container, edges: .bottom)
            } else {
                page
            }
        }
        .navigationTitle(textSize.isAccessibilitySize ? "" : interaction.kind.watchTitle)
        .task(id: interaction.plan) {
            let raw = interaction.plan ?? ""
            let prepared = await Task.detached { WatchText.shown(raw) }.value
            guard !Task.isCancelled else { return }
            planText = prepared
        }
        .task(id: interaction.dialog) {
            terminalOptions = interaction.dialog?.options.filter { $0.kind == nil } ?? []
            terminalPicks = Set(terminalOptions.filter { $0.checked == true }.map(\.key))
        }
        .onChange(of: interaction.questions) {
            questionIndex = 0
            picks = [:]
            triedEarly = false
        }
    }

    private var page: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Theme.Watch.blockSpacing) {
                if textSize.isAccessibilitySize {
                    Text(interaction.kind.watchTitle).font(Theme.Font.caption)
                }
                if WatchQuickAnswer.requiresPhone(interaction) {
                    WatchPhoneAnswerNotice()
                } else {
                    if let blockedReason {
                        Text(blockedReason).font(Theme.Font.caption).foregroundStyle(Theme.cautionText)
                    }
                    if let error = model.answerErrors[interaction.uid] {
                        Text(error).font(Theme.Font.caption).foregroundStyle(Theme.cautionText)
                    }
                    if submitting { ProgressView() }
                    content
                    if textSize.isAccessibilitySize { actions }
                    Button("On computer [Watch Request]") { act(.dismissed) }
                        .lineLimit(1)
                        .font(Theme.Font.caption).foregroundStyle(.secondary)
                        .disabled(!canAct)
                }
            }
        }
        .watchSnapshotScroll()
        .buttonStyle(.bordered)
        .tint(Theme.primaryText)
    }

    @ViewBuilder private var actions: some View {
        if !WatchQuickAnswer.requiresPhone(interaction) {
            if interaction.kind == .permission || interaction.kind == .plan {
                WatchDecisionControl(kind: interaction.kind, shape: .ring, resolve: act).disabled(!canAct)
            } else if interaction.kind == .question, !questions.isEmpty {
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: Theme.Space.sm) { questionNavigation }
                    VStack(spacing: Theme.Space.sm) { questionNavigation }
                }
            }
        }
    }

    @ViewBuilder private var content: some View {
        switch interaction.kind {
        case .question:
            questionPage
        case .plan:
            sessionLine
            WatchExpandableText(text: planText)
        case .permission:
            VStack(alignment: .leading, spacing: Theme.Space.xxs) {
                Text(interaction.toolDisplayName ?? interaction.summary ?? interaction.watchSummary)
                    .font(Theme.Watch.subject).fixedSize(horizontal: false, vertical: true)
                sessionLine
            }
            if interaction.toolDisplayName != nil, let summary = interaction.summary, !summary.isEmpty {
                WatchExpandableText(text: summary, font: Theme.Font.code)
            }
            if let reason = interaction.reason, !reason.isEmpty {
                WatchExpandableText(text: reason, font: Theme.Font.caption).foregroundStyle(.secondary)
            }
        case .screen:
            terminalPage
        case .elicitation:
            WatchPhoneAnswerNotice()
        }
    }

    @ViewBuilder private var sessionLine: some View {
        if let title = interaction.sessionTitle, !title.isEmpty {
            Text(title).font(Theme.Watch.tag).foregroundStyle(.secondary).lineLimit(1)
        }
    }

    @ViewBuilder private var questionPage: some View {
        if questions.indices.contains(questionIndex) {
            let question = questions[questionIndex]
            if questions.count > 1 {
                Text("Question \(questionIndex + 1) of \(questions.count)")
                    .font(Theme.Font.caption).foregroundStyle(.secondary)
            }
            Text(question.question).font(Theme.Font.heading)
            ForEach(question.options, id: \.label) { option in
                Button { choose(option, for: question) } label: {
                    WatchAnswerOptionLabel(option: option, selected: picks[question.question, default: []].contains(option.label))
                }
                .disabled(!canAct)
            }
            if triedEarly && picks[question.question, default: []].isEmpty {
                Label("Some questions are unanswered", systemImage: Theme.Icon.error)
                    .font(Theme.Font.caption).foregroundStyle(Theme.cautionText)
            }
        }
        Text("Answer in your own words on iPhone")
            .font(Theme.Font.caption).foregroundStyle(.secondary)
    }

    @ViewBuilder private var questionNavigation: some View {
        if questionIndex > 0 {
            Button("Previous") { questionIndex -= 1 }
                .foregroundStyle(Theme.onSolid).disabled(submitting)
        }
        if questionIndex + 1 < questions.count {
            Button("Next [Interaction Views f82c68]") {
                guard !picks[questions[questionIndex].question, default: []].isEmpty else {
                    triedEarly = true
                    WKInterfaceDevice.current().play(.retry)
                    return
                }
                questionIndex += 1
                triedEarly = false
            }
            .foregroundStyle(Theme.onSolid)
            .disabled(!canAct)
        } else if questions.count > 1 || questions.first?.multiSelect == true {
            Button("Submit") { submit() }
                .buttonStyle(.borderedProminent).tint(Theme.accent)
                .foregroundStyle(Theme.onSolid)
                .disabled(!canAct)
        }
    }

    @ViewBuilder private var terminalPage: some View {
        if let dialog = interaction.dialog {
            Text(dialog.question).font(Theme.Font.heading)
            if let command = dialog.command { WatchExpandableText(text: command, font: Theme.Font.code) }
            if let detail = dialog.detail { WatchExpandableText(text: detail) }
            if let warning = dialog.warning {
                Text(warning).font(Theme.Font.caption).foregroundStyle(Theme.cautionText)
            }
            ForEach(terminalOptions, id: \.key) { option in
                Button {
                    if dialog.multi == true {
                        if terminalPicks.contains(option.key) { terminalPicks.remove(option.key) }
                        else { terminalPicks.insert(option.key) }
                    } else { act(Resolution(option: option.key)) }
                } label: {
                    WatchAnswerOptionLabel(
                        option: QuestionOption(label: "\(option.key). \(option.label)", description: option.detail),
                        selected: dialog.multi == true && terminalPicks.contains(option.key)
                    )
                }
                .disabled(!canAct)
            }
            if dialog.multi == true {
                Button(dialog.submit == "Next" ? String(localized: "Next [Interaction Views f82c68]") : String(localized: "Submit")) {
                    act(Resolution(options: terminalOptions.map(\.key).filter(terminalPicks.contains)))
                }
                .buttonStyle(.borderedProminent).tint(Theme.accent)
                .foregroundStyle(Theme.onSolid)
                .disabled(!canAct || terminalPicks.isEmpty)
            }
        } else {
            Text("A dialog is open in the terminal").font(Theme.Font.body)
        }
        Text("Answer in your own words on iPhone")
            .font(Theme.Font.caption).foregroundStyle(.secondary)
        Button { showScreen.toggle() } label: { Text("Show screen").lineLimit(1) }
            .font(Theme.Font.caption)
        if showScreen {
            Text(interaction.screen ?? "").font(Theme.Font.code)
                .frame(maxWidth: .infinity, alignment: .leading)
            HStack(spacing: Theme.Space.sm) {
                Button("Esc") { act(Resolution(keys: ["esc"])) }
                Button("Enter") { act(Resolution(keys: ["enter"])) }
            }
            .disabled(!canAct)
        }
    }

    private func choose(_ option: QuestionOption, for question: Question) {
        guard canAct else { return }
        if question.multiSelect {
            var selected = picks[question.question, default: []]
            if selected.contains(option.label) { selected.remove(option.label) }
            else { selected.insert(option.label) }
            picks[question.question] = selected
        } else {
            picks[question.question] = [option.label]
            if questions.count == 1 { submit() }
        }
    }

    private func submit() {
        guard let answers = WatchQuickAnswer.answers(questions, picks: picks) else {
            triedEarly = true
            if let unanswered = questions.firstIndex(where: { picks[$0.question, default: []].isEmpty }) {
                questionIndex = unanswered
            }
            WKInterfaceDevice.current().play(.retry)
            return
        }
        act(Resolution(answers: answers))
    }

    private func act(_ resolution: Resolution) {
        guard canAct else { return }
        submitting = true
        Task {
            if await model.resolve(interaction, resolution) { dismiss() }
            submitting = false
        }
    }
}
