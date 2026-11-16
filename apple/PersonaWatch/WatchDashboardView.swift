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
                                .containerBackground(model.dashboard.needsYou > 0 ? StatusPalette.needsYou.tint : Theme.Watch.cardFill, for: .tabView)
                                .tag(page)
                        }
                    }
                    .tabViewStyle(.verticalPage)
                    .navigationTitle(textSize.isAccessibilitySize ? "" : selected.title)
                    .navigationDestination(for: WatchNavigation.Destination.self) { destination($0) }
                    .toolbar {
                        ToolbarItem(placement: .topBarLeading) {
                            TimelineView(.periodic(from: .now, by: Theme.Watch.staleAfter)) { context in
                                if model.error != nil || !model.groupFailures.isEmpty || !model.missing.isEmpty
                                    || model.lastUpdate.map({ context.date.timeIntervalSince($0) >= Theme.Watch.staleAfter }) == true {
                                    Button { Task { await model.refresh() } } label: { Theme.Icon.image(Theme.Icon.offline) }
                                        .foregroundStyle(Theme.cautionText)
                                        .accessibilityLabel(String(localized: "Retry [Components b8784c]"))
                                }
                            }
                        }
                        ToolbarItem(placement: .topBarTrailing) {
                            Button { recordingOpen = true } label: { Theme.Icon.image(Theme.Icon.dictate) }
                                .foregroundStyle(Theme.onSolid)
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

private struct WatchGlanceView: View {
    @Environment(WatchModel.self) private var model
    var selected: (WatchPage) -> Void

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Theme.Watch.lineSpacing) {
                if !model.isFresh { WatchFreshnessView() }
                if model.lastUpdate != nil {
                    Button { selected(.queue) } label: {
                        VStack(spacing: Theme.Watch.lineSpacing) {
                            WatchCountHeader(count: model.dashboard.needsYou)
                            HStack(spacing: Theme.Watch.lineSpacing) {
                                WatchCountTile(count: model.dashboard.approvals, kind: .approvals)
                                WatchCountTile(count: model.dashboard.questions, kind: .questions)
                                WatchCountTile(count: model.dashboard.messages, kind: .messages)
                            }
                        }
                    }
                    .buttonStyle(.plain)
                    if let request = model.dashboard.nextUp {
                        NavigationLink(value: WatchNavigation.Destination.interaction(group: request.group, id: request.id)) {
                            Text(request.watchSummary).font(Theme.Font.heading).lineLimit(2)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                        .buttonStyle(.plain)
                        .watchOpenGesture()
                        WatchQuickAnswerView(interaction: request)
                    } else if model.isFresh {
                        Text(model.dashboard.needsYou == 0 ? String(localized: "All caught up [Watch Dashboard]")
                             : String(localized: "Open Needs You to continue [Watch Dashboard]"))
                            .font(Theme.Font.caption).foregroundStyle(.secondary)
                    }
                    Button { selected(.running) } label: {
                        Label(StateName.count(.working, model.dashboard.working), systemImage: Theme.Icon.run)
                            .font(Theme.Font.caption).lineLimit(1)
                    }
                    .buttonStyle(.plain)
                    .frame(minHeight: Theme.Watch.minRowHeight)
                }
            }
            .padding(.horizontal, Theme.Space.s)
        }
        .watchSnapshotScroll()
    }
}

struct WatchCountHeader: View {
    var count: Int
    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: Theme.Space.s) {
            Text(count > Theme.Watch.countLimit ? "99+" : String(count)).font(Theme.Font.title).monospacedDigit()
            Text(StateName.needsYou.text).font(Theme.Font.caption)
            Spacer(minLength: Theme.Space.flush)
            Theme.Icon.image(Theme.Icon.disclosure).font(Theme.Font.label)
        }
        .foregroundStyle(Theme.needsYou)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(StateName.count(.needsYou, count))
    }
}

struct WatchCountTile: View {
    enum Kind {
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
    var count: Int
    var kind: Kind
    var body: some View {
        VStack(spacing: Theme.Space.flush) {
            Text(kind.title).font(Theme.Font.label)
            HStack(spacing: Theme.Watch.lineSpacing) {
                Theme.Icon.image(kind.symbol)
                Text(count > Theme.Watch.countLimit ? "99+" : String(count)).monospacedDigit()
            }
            .font(Theme.Font.captionStrong)
        }
        .padding(.vertical, Theme.Space.xs)
        .frame(maxWidth: .infinity)
        .background(Theme.Watch.cardFill, in: RoundedRectangle(cornerRadius: Theme.Watch.cardRadius))
        .opacity(count == 0 ? Theme.Watch.quietOpacity : 1)
        .accessibilityLabel(kind.spoken(count))
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
                                    .font(Theme.Font.caption).foregroundStyle(Theme.needsYou)
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
                                    Task { await model.resolve(request, request.kind == .plan ? Resolution(approve: false) : Resolution(allow: false)) }
                                } label: {
                                    Text("Deny [Interaction Views 84c4f6]").lineLimit(1)
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
                    VStack(alignment: .leading, spacing: Theme.Watch.lineSpacing) {
                        WatchTitle(session: running.session)
                        Text(running.session.stateLabel).font(Theme.Font.caption).foregroundStyle(running.session.stateTone.text)
                        if let progress = running.progress { WatchProgressBar(done: progress.done, started: progress.started) }
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

struct WatchProgressBar: View {
    var done: Int
    var started: Int
    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Watch.lineSpacing) {
            Text("\(done) of \(started) done [Watch Dashboard]").font(Theme.Font.caption).foregroundStyle(.secondary)
            GeometryReader { geometry in
                Capsule().fill(Theme.Watch.progressTrack)
                    .overlay(alignment: .leading) {
                        Capsule().fill(StatusPalette.working.dot)
                            .frame(width: geometry.size.width * Double(done) / Double(max(started, 1)))
                    }
            }
            .frame(height: Theme.Watch.progressHeight)
        }
        .accessibilityElement(children: .combine)
    }
}
