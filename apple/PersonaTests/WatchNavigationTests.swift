import Foundation
import Testing
@testable import Persona
import PersonaWire

struct WatchNavigationTests {
    private func route(_ value: String) throws -> WatchNavigation.Request {
        let url = try #require(URL(string: value))
        return try #require(WatchNavigation.url(url))
    }

    private let groups: Set<String> = ["", "other"]
    private let hubIDs = ["": "hub-first", "other": "hub-other"]

    private func session(group: String, machineID: String = "machine", sessionID: String = "session") throws -> Session {
        let payload: [String: Any] = [
            "machine_id": machineID, "session_id": sessionID, "title": "Agent", "cwd": "/code/project",
            "status": "idle", "state": "idle", "started_by_persona": false, "assistant": false,
            "pending_interactions": 0, "updated_at": "2026-11-16T00:00:00Z",
        ]
        var session = try JSON.decoder.decode(Session.self, from: JSONSerialization.data(withJSONObject: payload))
        session.group = group
        return session
    }

    private func interaction(group: String) -> Interaction {
        var interaction = Interaction(id: "request", machineID: "machine", sessionID: "session", kind: .permission)
        interaction.group = group
        return interaction
    }

    private func notification(hubID: String? = "hub-other", category: String = "INTERACTION_PERMISSION") throws -> WatchNavigation.Request {
        var payload: [AnyHashable: Any] = [
            "machine_id": "machine", "session_id": "session", "interaction_id": "request",
        ]
        if let hubID { payload["hub_id"] = hubID }
        return try #require(WatchNavigation.notification(category: category, userInfo: payload))
    }

    @Test func hubIdentitySeparatesCollidingSessionAndInteractionIDs() throws {
        let sessions = try [session(group: ""), session(group: "other")]
        let interactions = [interaction(group: ""), interaction(group: "other")]
        for group in groups {
            let request = try notification(hubID: hubIDs[group])
            #expect(WatchNavigation.resolve(request, hubIDs: hubIDs, groups: groups, sessions: sessions,
                                            interactions: interactions) == .interaction(group: group, id: "request"))
        }
    }

    @Test(arguments: ["SESSION_DONE", "TODO_DECIDE"])
    func sessionNotificationsStayInTheSendingHub(category: String) throws {
        let sessions = try [session(group: ""), session(group: "other")]
        let request = try notification(category: category)
        let destination = WatchNavigation.resolve(request, hubIDs: hubIDs, groups: groups, sessions: sessions,
                                                  interactions: [interaction(group: "other")])
        #expect(destination == .session(SessionKey(group: "other", machineID: "machine", sessionID: "session")))
    }

    @Test(arguments: ["INTERACTION_QUESTION", "INTERACTION_PLAN", "INTERACTION_INPUT", "INTERACTION_TERMINAL"])
    func interactionCategoriesOpenTheRequest(category: String) throws {
        let request = try notification(category: category)
        #expect(WatchNavigation.resolve(request, hubIDs: hubIDs, groups: groups, sessions: [],
                                        interactions: [interaction(group: "other")]) == .interaction(group: "other", id: "request"))
    }

    @Test func unknownHubUsesOnlyTheUniqueSessionOwner() throws {
        let request = try notification(hubID: "unknown")
        let sessions = try [session(group: "other")]
        #expect(WatchNavigation.resolve(request, hubIDs: hubIDs, groups: groups, sessions: sessions,
                                        interactions: [interaction(group: "other")]) == .interaction(group: "other", id: "request"))
        let colliding = try [session(group: ""), session(group: "other")]
        #expect(WatchNavigation.resolve(request, hubIDs: hubIDs, groups: groups, sessions: colliding,
                                        interactions: [interaction(group: "other")]) == .needsYou)
        #expect(WatchNavigation.resolve(request, hubIDs: hubIDs, groups: groups, sessions: [],
                                        interactions: [interaction(group: "other")]) == .needsYou)
    }

    @Test func unknownHubDoesNotTrustADecryptionGroupOrGuessTheDefault() throws {
        let request = try #require(WatchNavigation.notification(category: "SESSION_DONE", userInfo: [
            "hub_id": "unknown", "persona_group": "", "machine_id": "machine", "session_id": "session",
        ]))
        #expect(WatchNavigation.resolve(request, hubIDs: hubIDs, groups: [""], sessions: [], interactions: []) == .needsYou)
        let wrongMachine = try session(group: "", machineID: "different")
        #expect(WatchNavigation.resolve(request, hubIDs: hubIDs, groups: groups, sessions: [wrongMachine], interactions: []) == .needsYou)
    }

    @Test func olderPhoneWithoutHubIDsStillRequiresUniqueSessionOwnership() throws {
        let request = try notification(hubID: nil)
        let sessions = try [session(group: "other")]
        #expect(WatchNavigation.resolve(request, hubIDs: [:], groups: groups, sessions: sessions,
                                        interactions: [interaction(group: "other")]) == .interaction(group: "other", id: "request"))
        let colliding = try [session(group: ""), session(group: "other")]
        #expect(WatchNavigation.resolve(request, hubIDs: [:], groups: groups, sessions: colliding, interactions: []) == .needsYou)
    }

    @Test func removedGroupsAndDuplicateHubMappingsNeverSelectAnArbitraryGroup() throws {
        let request = try notification()
        let removedSession = try session(group: "other")
        #expect(WatchNavigation.resolve(request, hubIDs: hubIDs, groups: [""], sessions: [removedSession], interactions: []) == .needsYou)
        let colliding = try [session(group: ""), removedSession]
        #expect(WatchNavigation.resolve(request, hubIDs: ["": "hub-other", "other": "hub-other"], groups: groups,
                                        sessions: colliding, interactions: []) == .needsYou)
    }

    @Test func anAnsweredRequestFallsBackToItsOwnSessionNotAnotherHubsRequest() throws {
        let request = try notification()
        #expect(WatchNavigation.resolve(request, hubIDs: hubIDs, groups: groups, sessions: [],
                                        interactions: [interaction(group: "")]) == .session(
                                            SessionKey(group: "other", machineID: "machine", sessionID: "session")))
    }

    @Test func malformedNotificationsDoNotInventADestination() throws {
        #expect(WatchNavigation.notification(category: "UNRELATED", userInfo: [:]) == nil)
        #expect(WatchNavigation.notification(category: "INTERACTION_", userInfo: [:]) == nil)
        let request = try #require(WatchNavigation.notification(category: "TODO_DECIDE", userInfo: [
            "hub_id": "hub-other", "machine_id": 7, "session_id": "", "todo": ["id": "todo"],
        ]))
        #expect(WatchNavigation.resolve(request, hubIDs: hubIDs, groups: groups, sessions: [], interactions: []) == .needsYou)
    }

    @Test func urlsKeepExplicitGroupsAndDecodeTheirIdentifiers() throws {
        let request = try route("persona://open?group=other&machine=machine&session=session")
        let sessions = try [session(group: ""), session(group: "other")]
        #expect(WatchNavigation.resolve(request, hubIDs: hubIDs, groups: groups, sessions: sessions, interactions: []) == .session(
            SessionKey(group: "other", machineID: "machine", sessionID: "session")))
        let defaultRequest = try route("persona://ix?group=&id=request")
        #expect(WatchNavigation.resolve(defaultRequest, hubIDs: hubIDs, groups: groups, sessions: sessions,
                                        interactions: [interaction(group: ""), interaction(group: "other")]) == .interaction(group: "", id: "request"))
        let encoded = try route("persona://open?group=other&machine=machine%20name&session=session%26value")
        #expect(encoded.machineID == "machine name")
        #expect(encoded.sessionID == "session&value")
    }

    @Test func unscopedSessionLinksRequireUniqueOwnership() throws {
        let request = try route("persona://open?machine=machine&session=session")
        let sessions = try [session(group: ""), session(group: "other")]
        #expect(WatchNavigation.resolve(request, hubIDs: hubIDs, groups: groups, sessions: sessions, interactions: []) == .needsYou)
        let unique = try [session(group: "other")]
        #expect(WatchNavigation.resolve(request, hubIDs: hubIDs, groups: groups, sessions: unique, interactions: []) == .session(
            SessionKey(group: "other", machineID: "machine", sessionID: "session")))
    }

    @Test(arguments: ["dashboard", "needs-you"])
    func pageLinksRemainDistinct(host: String) throws {
        let request = try route("persona://\(host)")
        let expected: WatchNavigation.Destination = host == "dashboard" ? .dashboard : .needsYou
        #expect(WatchNavigation.resolve(request, hubIDs: [:], groups: [], sessions: [], interactions: []) == expected)
    }

    @Test(arguments: ["https://open?machine=machine&session=session", "persona://allday", "persona://record?meeting=1",
                      "persona://ix?id=", "persona://open?machine=machine", "persona://open?machine=machine&session=",
                      "persona://ix?group=&group=other&id=request"])
    func unrelatedOrMalformedLinksAreNotConsumed(link: String) throws {
        #expect(WatchNavigation.url(try #require(URL(string: link))) == nil)
    }

    @Test func coldLaunchRetainsTheRequestUntilTheModelLoads() throws {
        let request = try notification()
        var pending = WatchNavigation.Pending(request: request)
        #expect(pending.take(hubIDs: [:], groups: [], sessions: [], interactions: [], isLoaded: false) == nil)
        #expect(pending.request == request)
        let sessions = try [session(group: ""), session(group: "other")]
        #expect(pending.take(hubIDs: hubIDs, groups: groups, sessions: sessions,
                             interactions: [interaction(group: "other")], isLoaded: true) == .interaction(group: "other", id: "request"))
        #expect(pending.request == nil)
        #expect(pending.take(hubIDs: hubIDs, groups: groups, sessions: sessions, interactions: [], isLoaded: true) == nil)
    }

    @Test func latestTapWinsWhileLoading() throws {
        var pending = WatchNavigation.Pending(request: try notification())
        pending.receive(WatchNavigation.Request(target: .dashboard))
        #expect(pending.take(hubIDs: [:], groups: [], sessions: [], interactions: [], isLoaded: false) == nil)
        #expect(pending.take(hubIDs: [:], groups: [], sessions: [], interactions: [], isLoaded: true) == .dashboard)
    }

    @Test func summaryArrivingBeforeConfigurationDoesNotConsumeThePendingHubRoute() throws {
        let request = try notification()
        let sessions = try [session(group: ""), session(group: "other")]
        let interactions = [interaction(group: ""), interaction(group: "other")]
        var pending = WatchNavigation.Pending(request: request)
        #expect(pending.take(hubIDs: [:], groups: [], sessions: sessions,
                             interactions: interactions, isLoaded: true) == nil)
        #expect(pending.request == request)
        #expect(pending.take(hubIDs: hubIDs, groups: groups, sessions: sessions,
                             interactions: interactions, isLoaded: true) == .interaction(group: "other", id: "request"))
        #expect(pending.request == nil)
    }

    @Test func lateHubIdentityDisambiguatesAnOtherwiseAmbiguousSnapshot() throws {
        let request = try notification()
        let sessions = try [session(group: ""), session(group: "other")]
        let interactions = [interaction(group: ""), interaction(group: "other")]
        #expect(WatchNavigation.resolve(request, hubIDs: [:], groups: groups, sessions: sessions,
                                        interactions: interactions) == .needsYou)
        #expect(WatchNavigation.resolve(request, hubIDs: hubIDs, groups: groups, sessions: sessions,
                                        interactions: interactions) == .interaction(group: "other", id: "request"))
    }

    @Test func sharedHubIdentityCanUseAUniqueConfiguredSessionOwner() throws {
        let request = try notification()
        let duplicateIDs = ["": "hub-other", "other": "hub-other", "removed": "hub-other"]
        let sessions = try [session(group: "other"), session(group: "removed")]
        #expect(WatchNavigation.resolve(request, hubIDs: duplicateIDs, groups: groups, sessions: sessions,
                                        interactions: [interaction(group: "other"), interaction(group: "removed")])
                == .interaction(group: "other", id: "request"))
    }

    @Test func matchingInteractionIDMustAlsoMatchTheRequestedMachineAndSession() throws {
        let request = try notification()
        var wrongMachine = interaction(group: "other")
        wrongMachine.machineID = "another-machine"
        var wrongSession = interaction(group: "other")
        wrongSession.sessionID = "another-session"
        let fallback = WatchNavigation.Destination.session(
            SessionKey(group: "other", machineID: "machine", sessionID: "session"))
        for unrelated in [wrongMachine, wrongSession] {
            #expect(WatchNavigation.resolve(request, hubIDs: hubIDs, groups: groups, sessions: [],
                                            interactions: [unrelated]) == fallback)
        }
    }

    @Test func unscopedInteractionWithoutSessionIdentityNeverGuessesItsHub() throws {
        let request = try route("persona://ix?id=request")
        #expect(WatchNavigation.resolve(request, hubIDs: hubIDs, groups: groups, sessions: [],
                                        interactions: [interaction(group: "other")]) == .needsYou)
    }

    @Test func hubIdentityWinsOverAConflictingExplicitGroup() {
        let request = WatchNavigation.Request(target: .interaction("request"), hubID: "hub-other", group: "",
                                              machineID: "machine", sessionID: "session")
        #expect(WatchNavigation.resolve(request, hubIDs: hubIDs, groups: groups, sessions: [],
                                        interactions: [interaction(group: ""), interaction(group: "other")])
                == .interaction(group: "other", id: "request"))
    }

    @Test func watchConfigHubIDsAreOptionalAndRoundTrip() throws {
        let old = try JSONDecoder().decode(WatchConfigs.self, from: Data(#"{"configs":{},"names":{}}"#.utf8))
        #expect(old.hubIDs == nil)
        let current = WatchConfigs(configs: [:], hubIDs: hubIDs)
        let encoded = try JSONEncoder().encode(current)
        #expect(try JSONDecoder().decode(WatchConfigs.self, from: encoded) == current)
        struct LegacyConfigs: Decodable {
            var configs: [String: ServerConfig]
            var names: [String: String]
        }
        let legacy = try JSONDecoder().decode(LegacyConfigs.self, from: encoded)
        #expect(legacy.configs.isEmpty)
        #expect(legacy.names.isEmpty)
    }

    @MainActor @Test func phoneExportsOnlyCredentialIssuersWithWatchCredentials() {
        let config = ServerConfig(url: URL(string: "https://hub.example.com")!, token: "fixture-phone")
        let watch = ServerConfig(url: URL(string: "https://hub.example.com")!, token: "fixture-watch")
        let model = AppModel()
        model.registry = HubRegistry(hubs: [
            PairedHub(id: "first", config: config, hubID: "hub-first", watch: watch),
            PairedHub(id: "mesh", config: config, hubID: "hub-mesh", watch: watch),
            PairedHub(id: "other", config: config, group: "other", hubID: "hub-other", watch: watch),
            PairedHub(id: "unavailable", config: config, group: "unavailable", hubID: "hub-unavailable"),
        ])
        #expect(model.watchConfigs().hubIDs == hubIDs)
    }
}
