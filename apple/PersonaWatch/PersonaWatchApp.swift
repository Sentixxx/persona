import SwiftUI
import WatchKit
import PersonaWire

@main
struct PersonaWatchApp: App {
    /// The notification delegate for all-day recording's notices: set before launch finishes.
    @WKApplicationDelegateAdaptor(WatchAppDelegate.self) private var appDelegate
    @State private var model = WatchModel()
    @Environment(\.scenePhase) private var phase

    var body: some Scene {
        WindowGroup {
            WatchRootView()
                .onOpenURL { url in
                    if let request = WatchNavigation.url(url) {
                        WatchNotificationRoutes.shared.pending.receive(request)
                        return
                    }
                    // The All-Day Recording complication (persona://allday?action=…): start, continue or show it. The
                    // Record one (persona://record?meeting=1): straight into a meeting recording.
                    if HubNaming.accepts(scheme: url.scheme), let action = AllDayLink.action(of: url) {
                        WatchAllDay.shared.open(action)
                    } else if WatchModel.isMeetingLink(url) {
                        model.meetingAsked = true
                    } else {
                        model.openExtensionSurface(url)
                    }
                }
                .environment(model)
                .tint(Theme.accent)
                #if DEBUG
                .largeTextIfAsked()
                #endif
        }
        .onChange(of: phase) { _, p in
            if p == .active {
                // First: the microphone can open only now (a recording a call paused, a start a link asked for).
                WatchAllDay.shared.becameActive()
                Task { await model.refresh() }
                Task { await model.refreshExtensionSurfaces() }
            }
        }
        // The watch face's frog stays current while the app is not open (docs/apple/persona.md), and all-day recording
        // closes a day left open just after midnight: one request shared between them (`WatchBackgroundRefresh`).
        .backgroundTask(.appRefresh(WatchBackgroundRefresh.Job.pet.rawValue)) {
            await WatchBackgroundRefresh.run(.pet, model: model)
        }
        .backgroundTask(.appRefresh(WatchBackgroundRefresh.Job.allDay.rawValue)) {
            await WatchBackgroundRefresh.run(.allDay, model: model)
        }
        // What the phone sends a suspended or closed app (all-day recording's commands and acknowledgements) arrives
        // here: without this handler it would wait for the next time the app is opened.
        .backgroundTask(.watchConnectivity) { await WatchAllDay.shared.receiveConnectivity() }
    }
}

#if DEBUG
extension View {
    /// `-showLargeText YES`: an accessibility text size from the root down, for screenshots at large text that don't
    /// depend on the simulator applying `-UIPreferredContentSizeCategoryName` to a watch app.
    @ViewBuilder func largeTextIfAsked() -> some View {
        if UserDefaults.standard.bool(forKey: "showLargeText") { dynamicTypeSize(.accessibility5) } else { self }
    }
}
#endif

/// Watch state: seeded by the phone over WatchConnectivity, refreshed from the hubs directly while open. With several
/// groups of hubs on the phone (docs/protocol/multi-hub.md「Watch, Siri, Mac, and demo mode」) the watch gets each group's credential and shows them merged;
/// what it does goes to the group of what it acts on.
@Observable
final class WatchModel {
    /// Each group's credential ("" = the default group); one group from a phone before several hubs.
    var configs: [String: ServerConfig] = [:]
    var hubIDs: [String: String] = [:]
    @ObservationIgnored var extensionDeviceIDs: [String: String] = [:]
    var extensionCapabilities: [String: [String]] = [:]
    var extensionSurface: WatchExtensionDestination?
    /// What the groups are called (labels, when there are several).
    var names: [String: String] = [:]
    /// The phone's groups it could not get the watch a credential for yet (#1185); the watch says so and offers to
    /// sync again instead of using the phone's own.
    var missing: [String] = []
    /// The default (or first) group's: the watch is paired while there is one.
    var config: ServerConfig? { configs[""] ?? groups.first.flatMap { configs[$0] } }
    /// The groups, the default one first.
    var groups: [String] { configs.keys.sorted { ($0.isEmpty ? 0 : 1, $0) < ($1.isEmpty ? 0 : 1, $1) } }
    var sessions: [Session] = [] { didSet { updateDashboard() } }
    var interactions: [Interaction] = [] { didSet { updateDashboard() } }
    private(set) var dashboard = WatchDashboard(sessions: [], interactions: [])
    private var answers = WatchAnswers()
    var answerErrors: [String: String] { answers.errors }
    var answering: Set<String> { answers.answering }
    var isFresh: Bool {
        error == nil && groupFailures.isEmpty && missing.isEmpty
            && lastUpdate.map { Date.now.timeIntervalSince($0) < Theme.Watch.staleAfter } == true
    }

    func request(group: String, id: String) -> Interaction? {
        interactions.first { $0.group == group && $0.id == id } ?? answers.request(group: group, id: id)
    }
    /// The inbox's Needs You (Feishu messages, mail and connectors' items the AI says need the user), newest first.
    var inbox: [InboxItem] = [] { didSet { updateDashboard() } }
    var machines: [Machine] = []
    var error: String?
    var groupFailures: [String] = []
    var lastUpdate: Date?
    #if DEBUG
    var dashboardSample = false
    #endif

    private func updateDashboard() {
        dashboard = WatchDashboard(sessions: sessions, interactions: interactions, inbox: inbox)
    }
    /// The persona chosen on the phone: the Milk Frog shows only for its own.
    var persona = UserDefaults.standard.string(forKey: WatchModel.personaKey)
    /// The meetings' minutes the phone relays (`WatchMinutes`, docs/apple/recording.md「Apple Watch」).
    var minutes = WatchMinutes()
    /// A meeting recording asked for from outside the app (the complication): the home page opens it.
    var meetingAsked = false

    /// persona://record (the Record complication's link); the All-Day Recording complication's is
    /// persona://allday, a host of its own, read first (`AllDayLink`).
    static func isMeetingLink(_ url: URL) -> Bool {
        HubNaming.accepts(scheme: url.scheme) && url.host() == "record"
    }
    /// The Milk Frog's files on this watch.
    let pet = WatchPetPack()
    /// The Milk Frog on the watch face.
    @ObservationIgnored private let complication = WatchPetComplication()
    private static let petRefreshEvery: TimeInterval = 30 * 60
    private static let personaKey = "persona"
    private var petWanted: Bool { WatchPet.supports(persona) }

    /// The frog's state, once it has something to go on; nil without the Milk Frog or before its files are here.
    var petStatus: WatchPetStatus? {
        guard petWanted, pet.manifest != nil, lastUpdate != nil || error != nil else { return nil }
        #if DEBUG
        // `-showPetState needs_you|working|done|idle|sleep|offline`: the frog in that state (screenshots).
        if let raw = UserDefaults.standard.string(forKey: "showPetState"), let state = WatchPetState(rawValue: raw) {
            return WatchPetStatus(state: state, count: 3)
        }
        #endif
        return WatchPet.status(sessions: sessions, interactions: interactions, unreachable: error != nil,
                               partlyUnreachable: !groupFailures.isEmpty)
    }

    /// Each group's last successful fetch, kept in memory: a group whose refresh failed keeps it instead of being
    /// blanked by the groups that answered (#4369).
    @ObservationIgnored private var groupData: [String: WatchGroupData] = [:]
    /// Interaction uids the wrist already buzzed for, oldest first; persisted across launches and group outages.
    @ObservationIgnored private var seenInteractionUids: [String]
    private static let seenUidsKey = "seenInteractionUids"

    /// The default (or first) group's client: the inbox (each hub has its own; the watch shows the first group's).
    var api: APIClient? { groups.first.flatMap { api($0) } }
    /// A group's client.
    func api(_ group: String) -> APIClient? { configs[group].map { APIClient(config: $0, group: group) } }

    init() {
        NativeStateMigration.prepare()
        seenInteractionUids = UserDefaults.standard.stringArray(forKey: Self.seenUidsKey) ?? []
        #if DEBUG
        if WatchDashboardSamples.install(self) { return }
        #endif
        if let all = WatchConfigs.stored() {
            (configs, names, missing) = (all.configs, all.names, all.missing ?? [])
            hubIDs = all.hubIDs ?? [:]
            extensionDeviceIDs = all.deviceIDs ?? [:]
            extensionCapabilities = all.features ?? [:]
        }
        #if DEBUG
        if let s = UserDefaults.standard.string(forKey: "pairURL"), let c = ServerConfig(pairURL: s) { configs = ["": c] }
        // `-showWatchPet YES`: the Milk Frog as if chosen on the phone (screenshots).
        if UserDefaults.standard.bool(forKey: "showWatchPet") { persona = PersonaSelection.packageID }
        // `-showWatchMissing Office,Home`: those groups have no credential for the watch (#1185); `""`: the default group,
        // none at all without -pairURL.
        if let s = UserDefaults.standard.string(forKey: "showWatchMissing") {
            missing = s.split(separator: ",", omittingEmptySubsequences: false).map(String.init)
            missing.forEach { names[$0] = $0 }
        }
        WatchMeetingSamples.install(self) // `-showMeetingSample recording|minutes` (screenshots)
        WatchAllDaySamples.installIfAsked() // `-showAllDaySample recording|paused|interrupted|stopped|off|consent|deleted` (screenshots)
        #endif
        WatchSync.shared.onConfig = { [weak self] c in
            guard let self else { return }
            guard configs != ["": c] || !names.isEmpty || !missing.isEmpty ||
                  !extensionDeviceIDs.isEmpty || !extensionCapabilities.isEmpty else { return }
            configs = ["": c]
            hubIDs = [:]
            names = [:]
            missing = []
            extensionDeviceIDs = [:]
            extensionCapabilities = [:]
            syncExtensionSurfaces()
            WatchConfigs(configs: ["": c]).store()
            Task { await self.refresh() }
            Task { await self.refreshExtensionSurfaces() }
        }
        WatchSync.shared.onConfigs = { [weak self] all in
            guard let self else { return }
            guard configs != all.configs || names != all.names || missing != (all.missing ?? []) ||
                  extensionDeviceIDs != (all.deviceIDs ?? [:]) || extensionCapabilities != (all.features ?? [:]) ||
                  hubIDs != (all.hubIDs ?? [:]) else { return }
            configs = all.configs
            hubIDs = all.hubIDs ?? [:]
            names = all.names
            missing = all.missing ?? []
            extensionDeviceIDs = all.deviceIDs ?? [:]
            extensionCapabilities = all.features ?? [:]
            syncExtensionSurfaces()
            all.store()
            Task { await self.refresh() }
            Task { await self.refreshExtensionSurfaces() }
        }
        WatchSync.shared.onPersona = { [weak self] id in
            self?.persona = id
            UserDefaults.standard.set(id, forKey: WatchModel.personaKey)
            Task { await self?.fetchPet() }
        }
        WatchSync.shared.onMinutes = { [weak self] m in self?.minutes = m }
        WatchSync.shared.onSummary = { [weak self] s in
            guard let self, WatchGroupRefresh.acceptsSummary(at: s.at, lastUpdate: self.lastUpdate) else { return }
            // Which hubs fold side sessions (#7944): the watch reads no hello, so its own reads of them fold as the phone said.
            if let folding = s.sideFold {
                for g in Set(self.groups).union(folding) { SideFold.remember(folding.contains(g), group: g) }
            }
            // The phone's summary is every group merged; split it back so a later failed direct fetch keeps the right
            // group's data, and take the phone's word that the groups it covers are reachable (#4369).
            var byGroup: [String: WatchGroupData] = [:]
            for x in s.sessions { byGroup[x.group, default: .empty].sessions.append(x) }
            for x in s.interactions { byGroup[x.group, default: .empty].interactions.append(x) }
            for x in s.machines { byGroup[x.group, default: .empty].machines.append(x) }
            self.groupData = WatchGroupRefresh.mergeGroups(old: self.groupData, new: byGroup, failures: []).data
                .filter { self.configs[$0.key] != nil }
            self.groupFailures = []
            self.apply(sessions: s.sessions, interactions: s.interactions, machines: s.machines,
                       at: WatchGroupRefresh.dataDate(ofSummaryAt: s.at))
            if let inbox = s.inbox { self.applyInbox(inbox) }
            self.publishPet()
        }
        syncExtensionSurfaces()
        WatchRecordingTransfer.shared.start()
        // All-day recording's hooks and the phone's commands before WatchConnectivity activates: what it delivers at
        // once (a command queued while the app was closed) finds them.
        WatchAllDay.shared.install()
        WatchSync.shared.activate()
        Task { await refreshExtensionSurfaces() }
        Task { await poll() }
    }

    private func apply(sessions: [Session], interactions: [Interaction], machines: [Machine], at: Date = .now) {
        // Agents of quiet tasks and their questions are the main conversation's to tell (#1731), by the hub's word.
        let (sessions, interactions) = QuietTasks.leavingOut(sessions: sessions, interactions: interactions, quiet: \.quiet)
        // A side session lives in its parent's chat (#7944): no row of its own on the wrist, the parent in its folded state.
        // The phone's summary is folded already; folding it again changes nothing.
        let folded = SideFold.fold(sessions, groups: SideFold.rememberedGroups(groups)).listed
        // A muted agent's or space's card never reaches the wrist (#4360): it is neither shown nor buzzed for.
        let shown = answers.reconcile(WatchInteractions.leavingMuted(interactions))
        // Only a card seen for the first time buzzes: one that vanished with a failed group and came back with it is
        // already in the persisted record (#4369).
        let freshUids = WatchGroupRefresh.newHapticUids(seen: Set(seenInteractionUids), current: shown)
        func rank(_ s: Session) -> Int { s.state.priority }
        self.sessions = folded.filter { $0.state.isLive && !$0.assistant || $0.state == .needsYou || $0.state == .working }
            .sorted { rank($0) != rank($1) ? rank($0) < rank($1) : $0.sortDate > $1.sortDate }
        self.interactions = shown
        if !machines.isEmpty { self.machines = machines }
        lastUpdate = at
        guard !freshUids.isEmpty else { return }
        seenInteractionUids = WatchGroupRefresh.rememberSeen(seenInteractionUids, adding: freshUids)
        UserDefaults.standard.set(seenInteractionUids, forKey: Self.seenUidsKey)
        WKInterfaceDevice.current().play(.notification)
    }

    /// A card answered or ended is no longer worth remembering: its uid can buzz again if the hub ever reuses it.
    private func forgetSeen(_ uid: String) {
        guard seenInteractionUids.contains(uid) else { return }
        seenInteractionUids.removeAll { $0 == uid }
        UserDefaults.standard.set(seenInteractionUids, forKey: Self.seenUidsKey)
    }

    private func applyInbox(_ items: [InboxItem]) {
        let open = items.filter { !$0.isDone && $0.triage == .action }
        let hadNew = open.contains { it in !inbox.contains { $0.id == it.id } } && !inbox.isEmpty
        inbox = open
        if hadNew { WKInterfaceDevice.current().play(.notification) }
    }

    /// Every group's agents, requests and machines (each group's hub answers for its own), merged.
    func refresh() async {
        #if DEBUG
        if dashboardSample { return }
        #endif
        guard let first = api else { return }
        var fetched: [String: WatchGroupData] = [:]
        var failed: Set<String> = []
        var attempted = 0
        var failure: Error?
        let multi = configs.count > 1
        // Every group at once: one hub out of reach held the others back by its requests' 30 s every refresh (#4705).
        let apis = Dictionary(groups.compactMap { g in api(g).map { (g, $0) } }, uniquingKeysWith: { a, _ in a })
        let asked = groups.filter { apis[$0] != nil }
        attempted = asked.count
        await HubFanOut.run(asked, fetch: { g in
            let api = apis[g]!
            async let s = api.sessions()
            async let i = api.interactions()
            async let m = api.machines()
            return try await (s, i, m)
        }) { g, result in
            switch result {
            case .success(let (a, b, c)):
                fetched[g] = WatchGroupData(sessions: a, interactions: b,
                    machines: multi ? c.map { var m = $0; m.groupLabel = names[g] ?? g; return m } : c)
            case .failure(let error):
                failed.insert(g)
                failure = error
            }
        }
        // A failed group keeps its last successful data; only a group that answered replaces it (#4369). Groups the
        // watch no longer holds a credential for are dropped everywhere.
        let merged = WatchGroupRefresh.mergeGroups(old: groupData, new: fetched, failures: failed)
        groupData = merged.data.filter { configs[$0.key] != nil }
        // Every reachable group failing keeps the whole-page offline card (retry, last-updated line); only a partial
        // failure gets the per-group "earlier data" lines.
        let allFailed = failed.count == attempted
        groupFailures = allFailed ? [] : merged.failures.filter { configs[$0] != nil }
        if !fetched.isEmpty {
            let kept = groups.compactMap { groupData[$0] }
            apply(sessions: kept.flatMap(\.sessions), interactions: kept.flatMap(\.interactions),
                  machines: kept.flatMap(\.machines))
        }
        if let xx = try? await first.inbox(connectors: true) { applyInbox(xx) }
        error = failure.flatMap { allFailed ? ($0.watchShown ?? String(localized: "Can't reach the hub")) : nil }
        await fetchPet()
        publishPet()
    }

    /// The watch face's frog follows what this refresh learned; a face from before the frog was chosen goes away.
    private func publishPet() {
        complication.publish(petWanted ? petStatus : nil, at: lastUpdate, pack: pet)
        schedulePetRefresh()
    }

    /// Wakes the app in the background now and then, so the face does not go stale while the app is closed. watchOS
    /// decides when; past an hour without one the face says it does not know (WatchPetSnapshot.staleAfter). The request
    /// is shared with all-day recording (`WatchBackgroundRefresh`): watchOS keeps one per app.
    private func schedulePetRefresh() {
        WatchBackgroundRefresh.want(.pet, at: petWanted ? .now.addingTimeInterval(Self.petRefreshEvery) : nil)
    }

    func backgroundRefresh() async {
        await refresh()
    }

    /// The first group's hub, like the inbox's: every hub has the same built-in package.
    private func fetchPet() async {
        guard petWanted, let api else { return }
        await pet.fetch(api)
    }

    private func poll() async {
        while true {
            try? await Task.sleep(for: .seconds(8))
            if WKApplication.shared().applicationState == .active { await refresh() }
        }
    }

    /// A card on no session can always be answered (#4059); else as its session's source allows.
    func canAnswer(_ ix: Interaction) -> Bool { ix.canAnswer(session: sessions.first { $0.key == ix.sessionKey }) }

    @discardableResult
    func resolve(_ ix: Interaction, _ r: Resolution) async -> Bool {
        // To the hub of the interaction's own group.
        guard canAnswer(ix), let api = api(ix.group), answers.begin(ix, in: &interactions) else { return false }
        WKInterfaceDevice.current().play(.click)
        do {
            _ = try await api.resolve(ix.id, r)
            answers.complete(ix)
            forgetSeen(ix.uid)
            WKInterfaceDevice.current().play(.success)
            return true
        } catch {
            let expired = answers.receiveFailure(ix, status: (error as? APIError)?.status,
                message: error.watchShown ?? error.localizedDescription, in: &interactions)
            if expired { forgetSeen(ix.uid) }
            WKInterfaceDevice.current().play(expired ? .directionDown : .failure)
            return expired
        }
    }

    /// Each message carries an id (Codex app-server and runtime sessions refuse one without, codex_send_guard); a tap
    /// again after a failure sends the same id, so the hub types it at most once (#1185).
    @ObservationIgnored private var retries = RetryIDs<Unsent>()
    private struct Unsent: Hashable {
        var key: SessionKey
        var text: String
    }

    @discardableResult
    func send(_ key: SessionKey, _ text: String) async -> Bool {
        guard sessions.first(where: { $0.key == key })?.canSend == true, let api = api(key.group) else { return false }
        WKInterfaceDevice.current().play(.click)
        let unsent = Unsent(key: key, text: text)
        do {
            try await api.send(key, text: text, clientMsgID: retries.id(for: unsent))
            retries.sent(unsent)
            WKInterfaceDevice.current().play(.success)
            return true
        } catch {
            self.error = error.watchShown
            WKInterfaceDevice.current().play(.failure)
            return false
        }
    }

    func setDone(_ item: InboxItem) async {
        guard let api else { return }
        do {
            try await api.setInboxDone(item.id, true)
            inbox.removeAll { $0.id == item.id }
            WKInterfaceDevice.current().play(.success)
        } catch {
            self.error = error.watchShown
            WKInterfaceDevice.current().play(.failure)
        }
    }

    func reply(_ item: InboxItem, _ text: String) async -> Bool {
        guard let api else { return false }
        WKInterfaceDevice.current().play(.click)
        do {
            try await api.inboxReply(item.id, text: text)
            inbox.removeAll { $0.id == item.id }
            WKInterfaceDevice.current().play(.success)
            return true
        } catch {
            self.error = error.watchShown
            WKInterfaceDevice.current().play(.failure)
            return false
        }
    }

    func interrupt(_ key: SessionKey) async {
        guard sessions.first(where: { $0.key == key })?.canInterrupt == true, let api = api(key.group) else { return }
        // The stop haptic says the Agent stopped, so it plays only once the hub accepts the interrupt.
        do {
            try await api.interrupt(key)
            WKInterfaceDevice.current().play(.stop)
        } catch {
            self.error = error.watchShown
            WKInterfaceDevice.current().play(.failure)
        }
    }

    func machine(_ ref: MachineRef) -> Machine? { machines.first { $0.ref == ref } }
}





private extension Error {
    /// The watch has no connection title (the phone's Waiting for Network / Connecting…): no network is still worth a line here.
    var watchShown: String? { isOffline ? localizedDescription : shown }
}

/// A running agent's title in the list, with Claude Code's ultracode mark after its last word while that is on (#1307; no
/// switch on the watch). The mark is part of the text: beside the text's frame it sat after the first line of a title on
/// two, between its halves. It comes and goes with a state change, at once with Reduce Motion.
struct WatchTitle: View {
    var session: Session
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        let mark = Ultracode.rowMark(session)
        title(mark)
            .font(Theme.Font.heading)
            .lineLimit(2)
            .animation(reduceMotion ? nil : Theme.Motion.state, value: mark)
    }

    /// The label is the whole text's: an image's own inside a `Text` is not read.
    private func title(_ mark: Bool) -> Text {
        let title = session.displayTitle
        guard mark else { return Text(title) }
        let icon = Text(Theme.Icon.image(Theme.Icon.workflow)).font(Theme.Font.captionStrong).foregroundStyle(Theme.ai)
        return (Text(title) + Text(verbatim: "\u{00A0}") + icon)
            .accessibilityLabel(title + String(localized: ", ", comment: "List separator") + Ultracode.onWords)
    }
}

/// A workflow its agent runs in the background (#2935), on the watch: a small chip 「workflow 169/185」, not expanded.
/// Its count rolls when it changes (#3436, `numericText` is watchOS 10); nothing else moves, no clock.
struct WatchWorkflowChip: View {
    var run: WorkflowRun
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        let text = "workflow" + (run.progress.map { " \($0.done)/\($0.started)" } ?? "")
        HStack(spacing: Theme.Space.xs) {
            Theme.Icon.image(Theme.Icon.workflow)
            // Rolls when either number changes: a new agent (169/185 → 169/186) as well as one coming back.
            Text(text).lineLimit(1)
                .contentTransition(.numericText(value: Double((run.progress?.done ?? 0) + (run.progress?.started ?? 0))))
                .animation(reduceMotion ? nil : Theme.Motion.state, value: text)
        }
        .font(Theme.Font.labelStrong)
        .foregroundStyle(Theme.ai)
        .padding(.horizontal, Theme.Space.s)
        .padding(.vertical, Theme.Space.xxs)
        .background(Theme.aiTint, in: .capsule)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(String(localized: "Background \(text)"))
    }
}
