import Foundation
import WhoopStore

// MARK: - Progression suggestion
//
// A simple linear-progression heuristic: if the most recent session's sets for an exercise matched
// or beat the session before it (same rep count or more, at the same weight, on every set), suggest
// stepping the weight up; otherwise suggest repeating it. Deliberately not configurable per exercise
// (no progression-rule picker) — this is a first version, scoped to "linear is enough to start."

struct ProgressionSuggestion: Equatable {
    let suggestedWeightKg: Double
    let reasoning: String
}

enum ProgressionCalculator {
    static let increment: Double = 2.5

    /// `sets` = every logged set for ONE exercise, any order, spanning any number of sessions.
    static func suggest(from sets: [StrengthSetRow]) -> ProgressionSuggestion? {
        let working = sets.filter { !$0.isWarmup && $0.weightKg != nil }
        guard !working.isEmpty else { return nil }

        var order: [String] = []
        var bySession: [String: [StrengthSetRow]] = [:]
        for s in working.sorted(by: { $0.completedAt < $1.completedAt }) {
            if bySession[s.sessionId] == nil { order.append(s.sessionId) }
            bySession[s.sessionId, default: []].append(s)
        }
        guard let lastId = order.last,
              let last = bySession[lastId]?.sorted(by: { $0.setIndex < $1.setIndex }),
              let lastWeight = last.first?.weightKg else { return nil }

        guard order.count >= 2, let prevId = order.dropLast().last,
              let previous = bySession[prevId]?.sorted(by: { $0.setIndex < $1.setIndex }) else {
            return ProgressionSuggestion(
                suggestedWeightKg: lastWeight,
                reasoning: "Repeat last session's weight — not enough history yet to suggest more.")
        }

        // "Matched the weight" means the weight was steady across BOTH the last session's own sets AND
        // against the session before it — not just internally consistent within the last session. A
        // session logged at a different weight than the one before it (a manual jump, a deload, a
        // typo) shouldn't compound into a further step-up on top of whatever that change already was.
        let sameWeight = last.allSatisfy { $0.weightKg == lastWeight } && previous.first?.weightKg == lastWeight
        let metOrBeatEachSet = zip(last, previous).allSatisfy { (a, b) in (a.reps ?? 0) >= (b.reps ?? 0) }
        if sameWeight && metOrBeatEachSet && last.count >= previous.count {
            let stepped = lastWeight + increment
            return ProgressionSuggestion(
                suggestedWeightKg: stepped,
                reasoning: "You matched or beat every set last time — up \(String(format: "%.1f", increment)) kg.")
        }
        return ProgressionSuggestion(suggestedWeightKg: lastWeight, reasoning: "Repeat last session's weight.")
    }
}
