import Foundation

nonisolated struct WatchAnswers: Sendable {
    private var pending: [String: Interaction] = [:]
    private var accepted: Set<String> = []
    private(set) var errors: [String: String] = [:]

    var answering: Set<String> { Set(pending.keys) }

    func request(group: String, id: String) -> Interaction? {
        pending.values.first { $0.group == group && $0.id == id }
    }

    mutating func begin(_ interaction: Interaction, in interactions: inout [Interaction]) -> Bool {
        guard pending[interaction.uid] == nil, !accepted.contains(interaction.uid) else { return false }
        pending[interaction.uid] = interaction
        errors[interaction.uid] = nil
        interactions.removeAll { $0.uid == interaction.uid }
        return true
    }

    mutating func complete(_ interaction: Interaction) {
        pending[interaction.uid] = nil
        accepted.insert(interaction.uid)
        errors[interaction.uid] = nil
    }

    mutating func receiveFailure(_ interaction: Interaction, status: Int?, message: String,
                                 in interactions: inout [Interaction]) -> Bool {
        if status == 410 {
            complete(interaction)
            return true
        }
        fail(interaction, message: message, in: &interactions)
        return false
    }

    mutating func fail(_ interaction: Interaction, message: String, in interactions: inout [Interaction]) {
        guard let original = pending.removeValue(forKey: interaction.uid) else { return }
        errors[interaction.uid] = message
        if !interactions.contains(where: { $0.uid == interaction.uid }) { interactions.append(original) }
    }

    mutating func reconcile(_ interactions: [Interaction]) -> [Interaction] {
        accepted.formIntersection(interactions.map(\.uid))
        let present = Set(interactions.map(\.uid)).union(pending.keys)
        errors = errors.filter { present.contains($0.key) }
        return interactions.filter { pending[$0.uid] == nil && !accepted.contains($0.uid) }
    }
}
