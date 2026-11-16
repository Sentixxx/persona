import Foundation

nonisolated enum WatchNavigation {
    enum Destination: Hashable, Sendable {
        case dashboard
        case needsYou
        case interaction(group: String, id: String)
        case session(SessionKey)
    }

    struct Request: Equatable, Sendable {
        enum Target: Equatable, Sendable {
            case dashboard
            case needsYou
            case interaction(String)
            case session
        }

        var target: Target
        var hubID: String? = nil
        var group: String? = nil
        var machineID: String? = nil
        var sessionID: String? = nil
    }

    struct Pending: Equatable, Sendable {
        var request: Request? = nil

        mutating func receive(_ request: Request) {
            self.request = request
        }

        mutating func take(hubIDs: [String: String], groups: Set<String>, sessions: [Session],
                           interactions: [Interaction], isLoaded: Bool) -> Destination? {
            guard isLoaded, let request else { return nil }
            guard !groups.isEmpty || request.target == .dashboard || request.target == .needsYou else { return nil }
            self.request = nil
            return WatchNavigation.resolve(request, hubIDs: hubIDs, groups: groups,
                                           sessions: sessions, interactions: interactions)
        }
    }

    static func notification(category: String, userInfo: [AnyHashable: Any]) -> Request? {
        guard (category.hasPrefix("INTERACTION_") && category != "INTERACTION_")
                || category == "SESSION_DONE" || category == "TODO_DECIDE" else { return nil }
        let interactionID = nonempty(userInfo["interaction_id"] as? String)
        let target: Request.Target = category.hasPrefix("INTERACTION_")
            ? interactionID.map(Request.Target.interaction) ?? .session : .session
        return Request(target: target, hubID: nonempty(userInfo["hub_id"] as? String),
                       machineID: nonempty(userInfo["machine_id"] as? String),
                       sessionID: nonempty(userInfo["session_id"] as? String))
    }

    static func url(_ url: URL) -> Request? {
        guard HubNaming.accepts(scheme: url.scheme),
              let components = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return nil }
        let items = components.queryItems ?? []
        guard Set(items.map(\.name)).count == items.count else { return nil }
        let group = items.first { $0.name == "group" }.map { $0.value ?? "" }
        let machineID = nonempty(items.first { $0.name == "machine" }?.value)
        let sessionID = nonempty(items.first { $0.name == "session" }?.value)
        switch components.host {
        case "dashboard": return Request(target: .dashboard)
        case "needs-you": return Request(target: .needsYou)
        case "ix":
            guard let id = nonempty(items.first { $0.name == "id" }?.value) else { return nil }
            return Request(target: .interaction(id), group: group, machineID: machineID, sessionID: sessionID)
        case "open":
            guard let machineID, let sessionID else { return nil }
            return Request(target: .session, group: group, machineID: machineID, sessionID: sessionID)
        default: return nil
        }
    }

    static func resolve(_ request: Request, hubIDs: [String: String], groups: Set<String>,
                        sessions: [Session], interactions: [Interaction]) -> Destination {
        switch request.target {
        case .dashboard: return .dashboard
        case .needsYou: return .needsYou
        case .interaction, .session: break
        }
        guard let group = group(for: request, hubIDs: hubIDs, groups: groups, sessions: sessions) else {
            return .needsYou
        }
        if case .interaction(let id) = request.target,
           interactions.contains(where: {
               $0.group == group && $0.id == id
                   && (request.machineID == nil || $0.machineID == request.machineID)
                   && (request.sessionID == nil || $0.sessionID == request.sessionID)
           }) {
            return .interaction(group: group, id: id)
        }
        guard let machineID = request.machineID, let sessionID = request.sessionID else { return .needsYou }
        return .session(SessionKey(group: group, machineID: machineID, sessionID: sessionID))
    }

    private static func group(for request: Request, hubIDs: [String: String], groups: Set<String>,
                              sessions: [Session]) -> String? {
        if let hubID = request.hubID {
            let matching = groups.filter { hubIDs[$0] == hubID }
            if matching.count == 1 { return matching.first }
        } else if let group = request.group, groups.contains(group) {
            return group
        }
        guard let machineID = request.machineID, let sessionID = request.sessionID else { return nil }
        let owners = Set(sessions.filter {
            groups.contains($0.group) && $0.machineID == machineID && $0.sessionID == sessionID
        }.map(\.group))
        return owners.count == 1 ? owners.first : nil
    }

    private static func nonempty(_ value: String?) -> String? {
        value.flatMap { $0.isEmpty ? nil : $0 }
    }
}
