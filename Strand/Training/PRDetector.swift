import Foundation
import WhoopStore

// MARK: - Personal-record detection
//
// A PR is a strictly heavier weight than every prior completed set of the same exercise. Warm-ups
// and sets with no logged reps never count toward — or against — a PR; a tie is deliberately NOT a
// PR (ambiguous whether it's genuinely new).

enum PRDetector {
    /// True when `set` is a new max weight for its exercise, compared against `priorSets` (already
    /// scoped to the SAME exercise, in any order — only the max matters).
    static func isPR(_ set: StrengthSetRow, among priorSets: [StrengthSetRow]) -> Bool {
        guard !set.isWarmup, let weight = set.weightKg, let reps = set.reps, reps >= 1 else { return false }
        let priorBest = priorSets
            .filter { !$0.isWarmup && ($0.reps ?? 0) >= 1 }
            .compactMap(\.weightKg)
            .max()
        guard let priorBest else { return true }
        return weight > priorBest
    }
}
