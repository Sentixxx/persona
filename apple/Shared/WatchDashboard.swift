import Foundation

nonisolated struct WatchDashboard: Equatable, Sendable {
    enum BlockedReason: Equatable, Sendable {
        case requiresInput, missingSession, attach, computer
    }

    struct RequestGroup: Identifiable, Equatable, Sendable {
        let id: SessionKey
        let session: Session?
        let interactions: [Interaction]

        fileprivate var oldestDate: Date {
            if let first = interactions.first { return first.createdAt ?? .distantPast }
            return session?.stateSince ?? .distantPast
        }
    }

    struct Progress: Equatable, Sendable {
        let done: Int
        let started: Int
    }

    struct RunningSession: Identifiable, Equatable, Sendable {
        let session: Session
        let workflow: WorkflowRun?
        let progress: Progress?

        var id: SessionKey { session.key }
    }

    let needsYou: Int
    let approvals: Int
    let questions: Int
    let messages: Int
    let working: Int
    let backgroundWaiting: Int
    let unread: Int
    let nextUp: Interaction?
    let nextUpBlockedReason: BlockedReason?
    let queue: [RequestGroup]
    let running: [RunningSession]

    init(sessions: [Session], interactions: [Interaction], inbox: [InboxItem] = []) {
        let sessionsByKey = Dictionary(sessions.map { ($0.key, $0) }, uniquingKeysWith: { first, _ in first })
        let waiting = Self.waitingSessions(sessions: sessions, interactions: interactions)
        needsYou = waiting.count
        approvals = interactions.filter { $0.kind == .permission || $0.kind == .plan }.count
        questions = interactions.filter { $0.kind == .question || $0.kind == .screen }.count
        messages = inbox.filter { !$0.isDone && $0.triage == .action }.count

        let orderedRequests = interactions.sorted(by: Self.oldestRequest)
        let answerable = orderedRequests.filter {
            Self.blockedReason(for: $0, session: sessionsByKey[$0.sessionKey]) == nil
        }
        let next = answerable.min { first, second in
            let firstPriority = Self.priority(first.kind), secondPriority = Self.priority(second.kind)
            return firstPriority != secondPriority ? firstPriority < secondPriority : Self.oldestRequest(first, second)
        } ?? orderedRequests.first
        nextUp = next
        nextUpBlockedReason = next.flatMap { Self.blockedReason(for: $0, session: sessionsByKey[$0.sessionKey]) }

        let requestsBySession = Dictionary(grouping: orderedRequests, by: \.sessionKey)
        queue = waiting.map { key in
            RequestGroup(id: key, session: sessionsByKey[key], interactions: requestsBySession[key] ?? [])
        }.sorted { first, second in
            first.oldestDate != second.oldestDate ? first.oldestDate < second.oldestDate : first.id.path < second.id.path
        }

        let active = sessionsByKey.values.filter { $0.state == .working || $0.state == .unread }
        working = active.filter { $0.state == .working }.count
        backgroundWaiting = active.filter(\.waitsInBackground).count
        unread = active.filter { $0.state == .unread }.count
        running = active.sorted { first, second in
            if first.state != second.state { return first.state == .working }
            return first.sortDate != second.sortDate ? first.sortDate < second.sortDate : first.id < second.id
        }.map { session in
            let workflow = session.leadWorkflow
            let progress = workflow.flatMap { run -> Progress? in
                guard let started = run.agentsStarted, started > 0 else { return nil }
                return Progress(done: min(max(run.agentsDone ?? 0, 0), started), started: started)
            }
            return RunningSession(session: session, workflow: workflow, progress: progress)
        }
    }

    static func waitingSessions(sessions: [Session], interactions: [Interaction]) -> Set<SessionKey> {
        Set(interactions.map(\.sessionKey)).union(sessions.filter { $0.state == .needsYou }.map(\.key))
    }

    private static func blockedReason(for interaction: Interaction, session: Session?) -> BlockedReason? {
        if interaction.requiresInput || interaction.secret == true { return .requiresInput }
        guard !interaction.canAnswer(session: session) else { return nil }
        guard let session else { return .missingSession }
        return session.canAttach ? .attach : .computer
    }

    private static func oldestRequest(_ first: Interaction, _ second: Interaction) -> Bool {
        let firstDate = first.createdAt ?? .distantPast
        let secondDate = second.createdAt ?? .distantPast
        return firstDate != secondDate ? firstDate < secondDate : first.uid < second.uid
    }

    private static func priority(_ kind: InteractionKind) -> Int {
        switch kind {
        case .permission: 0
        case .plan: 1
        case .question: 2
        case .screen: 3
        case .elicitation: 4
        }
    }
}
