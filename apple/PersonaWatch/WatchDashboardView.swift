import SwiftUI
import WatchKit
import PersonaWire

private enum WatchPage: String, CaseIterable, Identifiable {
    case glance, queue, running, recordings
    var id: String { rawValue }
    var title: String {
        switch self {
        case .glance: String(localized: "Glance [Watch Dashboard]")
        case .queue: StateName.needsYou.text
        case .running: String(localized: "Running [Session Panes 1f0eb9]")
        case .recordings: String(localized: "Recordings [Watch Dashboard]")
        }
    }
}

struct WatchRootView: View {
    @Environment(WatchModel.self) private var model
    @Environment(\.scenePhase) private var phase
    @Environment(\.dynamicTypeSize) private var textSize
    @State private var selected: WatchPage = .glance
    @State private var paths: [WatchPage: [WatchNavigation.Destination]] = [:]
    @State private var allDay = WatchAllDay.shared
    @State private var routes = WatchNotificationRoutes.shared
    @State private var recordingOpen = false
    @State private var meetingOpen = false
    @State private var leftAt: Date?
    @State private var refreshingRoute = false
    #if DEBUG
    @State private var debugOpened = false
    @State private var debugPage: String?
    #endif

    var body: some View {
        Group {
            if model.config == nil {
                NavigationStack { WatchPairView() }
            } else {
                NavigationStack(path: Binding(get: { paths[selected] ?? [] }, set: { paths[selected] = $0 })) {
                    TabView(selection: $selected) {
                        ForEach(WatchPage.allCases) { page in
                            VStack(alignment: .leading, spacing: Theme.Watch.lineSpacing) {
                                if textSize.isAccessibilitySize {
                                    Text(page.title).font(Theme.Font.caption).fixedSize(horizontal: false, vertical: true)
                                        .padding(.horizontal, Theme.Space.s)
                                }
                                content(page)
                            }
                                .containerBackground(Color.black, for: .tabView)
                                .tag(page)
                        }
                    }
                    .tabViewStyle(.verticalPage)
                    .navigationTitle(textSize.isAccessibilitySize || selected == .glance ? "" : selected.title)
                    .navigationDestination(for: WatchNavigation.Destination.self) { destination($0) }
                    .toolbar {
                        ToolbarItem(placement: .topBarLeading) {
                            TimelineView(.periodic(from: .now, by: Theme.Watch.staleAfter)) { context in
                                if model.error != nil || !model.groupFailures.isEmpty || !model.missing.isEmpty
                                    || model.lastUpdate.map({ context.date.timeIntervalSince($0) >= Theme.Watch.staleAfter }) == true {
                                    Button { Task { await model.refresh() } } label: { Theme.Icon.image(Theme.Icon.offline) }
                                        .foregroundStyle(Theme.onSolid)
                                        .accessibilityLabel(String(localized: "Retry [Components b8784c]"))
                                }
                            }
                        }
                        ToolbarItem(placement: .topBarTrailing) {
                            Button { recordingOpen = true } label: { Theme.Icon.image(Theme.Icon.dictate) }
                                .buttonStyle(.plain)
                                .foregroundStyle(.secondary)
                                .accessibilityLabel(String(localized: "Record [Watch Dashboard]"))
                        }
                    }
                }
            }
        }
        .onChange(of: routes.pending, initial: true) { _, _ in refreshRoute() }
        .onChange(of: model.lastUpdate) { _, _ in consumeRoute(); openDebugDestination() }
        .onChange(of: model.hubIDs) { _, _ in refreshRoute() }
        .onChange(of: model.groups) { _, _ in refreshRoute() }
        .onChange(of: phase) { _, phase in
            if phase == .background { leftAt = .now }
            if phase == .active {
                if let leftAt, Date.now.timeIntervalSince(leftAt) >= Theme.Watch.returnToGlanceAfter {
                    selected = .glance
                    paths = [:]
                }
                leftAt = nil
                consumeRoute()
            }
        }
        .sheet(isPresented: $recordingOpen) { sheet { WatchRecordingView() } }
        .sheet(isPresented: $meetingOpen) { sheet { WatchRecordingView(startsMeeting: true) } }
        .sheet(isPresented: Binding(get: { allDay.pageRequested }, set: { allDay.pageRequested = $0 })) {
            sheet { WatchAllDayView() }
        }
        .sheet(item: Binding(get: { model.extensionSurface }, set: { model.extensionSurface = $0 })) { destination in
            sheet { WatchExtensionSurfacePage(destination: destination) }
        }
        .onChange(of: model.meetingAsked, initial: true) { _, asked in
            guard asked else { return }
            model.meetingAsked = false
            selected = .recordings
            meetingOpen = true
        }
        .onAppear { openDebugDestination() }
        #if DEBUG
        .sheet(isPresented: Binding(get: { debugPage != nil }, set: { if !$0 { debugPage = nil } })) {
            sheet {
                switch debugPage {
                case "pet": WatchPetView()
                case "complication": PetComplicationPreview()
                case "allday-complication": AllDayComplicationPreview()
                case "record-complication": MeetingRecordingComplicationPreview()
                case "minutes", "minutes-writing":
                    if let meeting = model.minutes.meetings.first(where: { $0.state == (debugPage == "minutes" ? .ready : .writing) }) {
                        WatchMinutesView(meeting: meeting)
                    }
                case "inbox":
                    if let item = model.inbox.first { WatchInboxItemView(item: item) }
                default: EmptyView()
                }
            }
        }
        #endif
    }

    @ViewBuilder private func content(_ page: WatchPage) -> some View {
        switch page {
        case .glance: WatchGlanceView(selected: { selected = $0 })
        case .queue: WatchQueueView()
        case .running: WatchRunningView()
        case .recordings:
            List {
                WatchAllDayCard()
                WatchMeetingEntries()
                if let status = model.petStatus { WatchPetRow(status: status).watchCard() }
            }
        }
    }

    @ViewBuilder private func destination(_ destination: WatchNavigation.Destination) -> some View {
        switch destination {
        case .interaction(let group, let id):
            if let request = model.request(group: group, id: id) {
                WatchInteractionView(interaction: request)
            } else {
                WatchQueueView()
            }
        case .session(let key):
            if let session = model.sessions.first(where: { $0.key == key }) {
                WatchSessionView(session: session)
            } else {
                WatchQueueView()
            }
        case .needsYou: WatchQueueView()
        case .dashboard: WatchGlanceView(selected: { selected = $0 })
        }
    }

    private func sheet<Content: View>(@ViewBuilder content: () -> Content) -> some View {
        NavigationStack { content() }
            #if DEBUG
            .largeTextIfAsked()
            #endif
    }

    private func consumeRoute() {
        guard !refreshingRoute else { return }
        guard let destination = routes.pending.take(hubIDs: model.hubIDs, groups: Set(model.groups),
                sessions: model.sessions, interactions: model.interactions, isLoaded: model.lastUpdate != nil) else { return }
        paths = [:]
        switch destination {
        case .dashboard: selected = .glance
        case .needsYou: selected = .queue
        case .interaction:
            selected = .queue
            paths[.queue] = [destination]
        case .session:
            selected = .running
            paths[.running] = [destination]
        }
    }

    private func refreshRoute() {
        guard routes.pending.request != nil, !refreshingRoute else { return }
        refreshingRoute = true
        Task {
            await model.refresh()
            refreshingRoute = false
            consumeRoute()
        }
    }

    private func openDebugDestination() {
        #if DEBUG
        guard !debugOpened else { return }
        if let page = UserDefaults.standard.string(forKey: "openWatchPage").flatMap(WatchPage.init(rawValue:)) {
            selected = page
        }
        guard model.lastUpdate != nil || model.config == nil else { return }
        debugOpened = true
        recordingOpen = UserDefaults.standard.bool(forKey: "openRecording")
        if UserDefaults.standard.bool(forKey: "openInboxFirst") { debugPage = "inbox" }
        guard let item = UserDefaults.standard.string(forKey: "openWatchItem") else { return }
        if item == "running" { selected = .running }
        else if item == "inbox" { selected = .queue }
        else if item == "allday" { allDay.pageRequested = true }
        else if ["pet", "complication", "allday-complication", "record-complication", "minutes", "minutes-writing"].contains(item) {
            debugPage = item
        } else if item == "session" || item.hasPrefix("session:") {
            if let session = model.sessions.first(where: { item == "session" || "session:" + $0.sessionID == item }) {
                selected = .running
                paths[.running] = [.session(session.key)]
            }
        } else if let request = model.interactions.first(where: { $0.kind.rawValue == item }) {
            selected = .queue
            paths[.queue] = [.interaction(group: request.group, id: request.id)]
        }
        #endif
    }
}

/// What needs you, at a glance: the count ring, the next request with its answer, and how many agents are working.
/// With fresh data and a permission or plan request next, at standard text sizes, the page is one fixed screen:
/// ring, request, decision. A raised wrist sees what is next and can answer without scrolling; the request's words
/// shorten to fit. Otherwise the page scrolls and the answer follows the request.
private struct WatchGlanceView: View {
    @Environment(WatchModel.self) private var model
    @Environment(\.dynamicTypeSize) private var textSize
    var selected: (WatchPage) -> Void
    @State private var submitting = false

    private var pinned: Interaction? {
        guard !textSize.isAccessibilitySize, model.isFresh, let request = model.dashboard.nextUp,
              request.kind == .permission || request.kind == .plan,
              !WatchQuickAnswer.requiresPhone(request), model.canAnswer(request) else { return nil }
        return request
    }

    var body: some View {
        if let request = pinned {
            VStack(alignment: .leading, spacing: Theme.Space.s) {
                Button { selected(.queue) } label: { WatchCountSummary(dashboard: model.dashboard) }
                    .buttonStyle(.plain)
                NavigationLink(value: WatchNavigation.Destination.interaction(group: request.group, id: request.id)) {
                    VStack(alignment: .leading, spacing: Theme.Space.xxs) {
                        Label(request.kind.watchTitle, systemImage: request.kind.watchSymbol)
                            .font(Theme.Watch.tag).foregroundStyle(request.kind.watchTint).lineLimit(1)
                        Text(request.watchSummary).font(Theme.Watch.subject).lineLimit(2)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .watchOpenGesture()
                if let error = model.answerErrors[request.uid] {
                    Text(error).font(Theme.Watch.tag).foregroundStyle(Theme.cautionText).lineLimit(2)
                }
                Spacer(minLength: Theme.Space.flush)
                WatchDecisionControl(kind: request.kind, shape: .capsule) { resolve(request, $0) }
                    .disabled(submitting || model.answering.contains(request.uid))
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .padding(.horizontal, Theme.Space.xs)
            .padding(.bottom, Theme.Space.s)
            .ignoresSafeArea(.container, edges: .bottom)
        } else {
            scroll
        }
    }

    private var scroll: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Theme.Space.s) {
                if !model.isFresh { WatchFreshnessView() }
                if model.lastUpdate != nil {
                    Button { selected(.queue) } label: { WatchCountSummary(dashboard: model.dashboard) }
                        .buttonStyle(.plain)
                    if let request = model.dashboard.nextUp {
                        NavigationLink(value: WatchNavigation.Destination.interaction(group: request.group, id: request.id)) {
                            WatchRequestSubject(request: request, lineLimit: 3).contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .watchOpenGesture()
                        WatchQuickAnswerView(interaction: request)
                    } else if model.isFresh {
                        Text(model.dashboard.needsYou == 0 ? String(localized: "All caught up [Watch Dashboard]")
                             : String(localized: "Open Needs You to continue [Watch Dashboard]"))
                            .font(Theme.Watch.subject)
                    }
                    Button { selected(.running) } label: {
                        Label(StateName.count(.working, model.dashboard.working), systemImage: Theme.Icon.run)
                            .font(Theme.Watch.tag).foregroundStyle(.secondary).lineLimit(1)
                            .frame(maxWidth: .infinity, minHeight: Theme.Watch.minRowHeight, alignment: .leading)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, Theme.Space.xs)
        }
        .watchSnapshotScroll()
    }

    private func resolve(_ request: Interaction, _ resolution: Resolution) {
        guard !submitting, !model.answering.contains(request.uid), model.canAnswer(request) else { return }
        submitting = true
        Task {
            await model.resolve(request, resolution)
            submitting = false
        }
    }
}

/// Approvals, questions and messages: their names and what VoiceOver says for a count.
enum WatchCountKind {
    case approvals, questions, messages
    var title: String {
        switch self {
        case .approvals: String(localized: "Approvals [Watch Dashboard]")
        case .questions: String(localized: "Questions [Watch Dashboard]")
        case .messages: String(localized: "Messages [Watch Dashboard]")
        }
    }
    var symbol: String {
        switch self {
        case .approvals: Theme.Icon.askFirst
        case .questions: Theme.Icon.question
        case .messages: Theme.Icon.inbox
        }
    }
    func spoken(_ count: Int) -> String {
        switch self {
        case .approvals: String(localized: "\(count) approval requests [Watch Dashboard]")
        case .questions: String(localized: "\(count) question requests [Watch Dashboard]")
        case .messages: String(localized: "\(count) messages needing you [Watch Dashboard]")
        }
    }
}

private struct WatchFreshnessView: View {
    @Environment(WatchModel.self) private var model
    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Watch.lineSpacing) {
            if model.error != nil {
                Label(String(localized: "Can't reach the hub"), systemImage: Theme.Icon.offline)
                    .foregroundStyle(Theme.caution)
                Button { Task { await model.refresh() } } label: { Text("Retry [Components b8784c]").lineLimit(1) }
            } else if model.lastUpdate == nil {
                ProgressView(String(localized: "Loading [Persona Watch App d04fcb]"))
            }
            ForEach(model.groupFailures, id: \.self) { group in
                Text("Can't reach “\(model.names[group] ?? String(localized: "Another group [Watch Dashboard]"))”; some data may be missing or older")
                    .foregroundStyle(Theme.caution)
            }
            if let updated = model.lastUpdate {
                TimelineView(.periodic(from: updated, by: Theme.Watch.staleAfter)) { context in
                    if model.error != nil || !model.groupFailures.isEmpty || context.date.timeIntervalSince(updated) >= Theme.Watch.staleAfter {
                        Text("Updated \(updated, style: .relative) ago [Watch Dashboard]").foregroundStyle(.secondary)
                    }
                }
            }
            if !model.missing.isEmpty {
                Text("Some groups need pairing [Watch Dashboard]").foregroundStyle(Theme.caution)
                WatchSyncButton()
            }
        }
        .font(Theme.Font.caption)
    }
}

private struct WatchQueueView: View {
    @Environment(WatchModel.self) private var model
    var body: some View {
        List {
            if !model.isFresh { WatchFreshnessView() }
            ForEach(model.dashboard.queue) { group in
                Section(group.session?.displayTitle ?? group.interactions.first?.sessionTitle ?? StateName.needsYou.text) {
                    ForEach(group.interactions, id: \.uid) { request in
                        NavigationLink(value: WatchNavigation.Destination.interaction(group: request.group, id: request.id)) {
                            VStack(alignment: .leading, spacing: Theme.Watch.lineSpacing) {
                                Label(request.kind.watchTitle, systemImage: request.kind.watchSymbol)
                                    .font(Theme.Watch.tag).foregroundStyle(request.kind.watchTint)
                                Text(request.watchSummary).font(Theme.Font.heading)
                                if let error = model.answerErrors[request.uid] {
                                    Text(error).font(Theme.Font.caption).foregroundStyle(Theme.danger)
                                }
                            }
                        }
                        .watchCard()
                        .swipeActions(allowsFullSwipe: false) {
                            if (request.kind == .permission || request.kind == .plan), !request.requiresInput,
                               request.secret != true, model.canAnswer(request) {
                                Button(role: .destructive) {
                                    Task { await model.resolve(request, WatchQuickAnswer.negativeResolution(for: request.kind)) }
                                } label: {
                                    if request.kind == .plan {
                                        Text("Revise [Watch Plan]").lineLimit(1)
                                    } else {
                                        Text("Deny [Interaction Views 84c4f6]").lineLimit(1)
                                    }
                                }
                            }
                        }
                    }
                    if group.interactions.isEmpty, let session = group.session {
                        NavigationLink(value: WatchNavigation.Destination.session(session.key)) {
                            Text("Open session [Watch Dashboard]").font(Theme.Font.heading)
                        }.watchCard()
                    }
                }
            }
            if !model.inbox.isEmpty {
                Section(String(localized: "Messages [Watch Dashboard]")) {
                    ForEach(model.inbox) { item in
                        NavigationLink { WatchInboxItemView(item: item) } label: { WatchInboxRow(item: item) }.watchCard()
                    }
                }
            }
            if model.dashboard.needsYou == 0 && model.inbox.isEmpty && model.isFresh {
                Text("All caught up [Watch Dashboard]").font(Theme.Font.caption).watchCard()
            }
        }
        .refreshable { await model.refresh() }
    }
}

private struct WatchRunningView: View {
    @Environment(WatchModel.self) private var model
    var body: some View {
        List {
            if !model.isFresh { WatchFreshnessView() }
            ForEach(model.dashboard.running) { running in
                NavigationLink(value: WatchNavigation.Destination.session(running.session.key)) {
                    HStack(spacing: Theme.Space.s) {
                        VStack(alignment: .leading, spacing: Theme.Watch.lineSpacing) {
                            WatchTitle(session: running.session)
                            Text(running.session.stateLabel).font(Theme.Font.caption).foregroundStyle(running.session.stateTone.text)
                            if let progress = running.progress {
                                Text("\(progress.done) of \(progress.started) done [Watch Dashboard]")
                                    .font(Theme.Watch.tag).foregroundStyle(.secondary).accessibilityHidden(true)
                            }
                        }
                        Spacer(minLength: Theme.Space.flush)
                        if let progress = running.progress { WatchProgressRing(done: progress.done, started: progress.started) }
                    }
                }.watchCard()
            }
            if model.dashboard.running.isEmpty && model.isFresh {
                Text("No agents running").font(Theme.Font.caption).watchCard()
            }
        }
        .refreshable { await model.refresh() }
    }
}
