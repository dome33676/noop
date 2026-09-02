import Foundation
import WhoopStore

// MARK: - Template plan (app-layer JSON shape for `strengthTemplate.planJSON`)
//
// WhoopStore stores `planJSON` as a plain String (matching the `workout.zonesJSON` convention: a
// structured sub-shape that's always read/written as a whole doesn't need its own tables). This file
// owns the actual shape + encode/decode, keeping WhoopStore storage-agnostic about what's inside.

/// One exercise's plan within a template: an ORDERED list of per-set targets (so a pyramid — e.g.
/// 12 / 10 / 8 reps at rising weight — is expressible, not just one target repeated).
struct TemplateExercisePlan: Codable, Equatable {
    var exerciseName: String
    var sets: [TemplateSetPlan]
}

/// One planned set's target. Both nil is valid (an exercise you just want reps-only or "as many as
/// possible" for).
struct TemplateSetPlan: Codable, Equatable {
    var targetReps: Int?
    var targetWeightKg: Double?
}

extension StrengthTemplateRow {
    /// Decode `planJSON`. Malformed/legacy JSON decodes to an empty plan rather than throwing — a
    /// template screen with no exercises is recoverable; a crash on open is not.
    var plan: [TemplateExercisePlan] {
        (try? JSONDecoder().decode([TemplateExercisePlan].self, from: Data(planJSON.utf8))) ?? []
    }

    static func encode(_ plan: [TemplateExercisePlan]) -> String {
        (try? String(data: JSONEncoder().encode(plan), encoding: .utf8)) ?? "[]"
    }
}
