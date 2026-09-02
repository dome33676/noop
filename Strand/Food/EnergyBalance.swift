import Foundation

// MARK: - Daily energy balance
//
// Today's actual net calorie balance — independent of any calorie GOAL: positive means a deficit
// (fewer calories eaten than burned, i.e. "saved"), negative means a surplus (more eaten than
// burned). Deliberately separate from `CalorieTarget` (which answers "did I hit my chosen goal");
// this answers "what actually happened today, energy-wise".

enum EnergyBalance {
    /// `bmr` + `activeKcal` burned, minus `eatenKcal`. Positive = deficit/saved, negative = surplus.
    static func dailyBalance(bmr: Double, activeKcal: Double, eatenKcal: Double) -> Double {
        (bmr + activeKcal) - eatenKcal
    }
}
