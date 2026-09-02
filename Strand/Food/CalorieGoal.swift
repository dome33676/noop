import Foundation
import StrandAnalytics

// MARK: - Calorie target
//
// Turns a profile (weight/height/age/sex) + a goal into a daily calorie target. TDEE (total daily
// energy expenditure) is derived from the user's own recently-MEASURED burn (BMR + Apple Health
// active calories, averaged over the last few days) rather than a manually-picked activity-level
// multiplier — more accurate once there's a few days of data, and needs no extra setup step. A
// sedentary-ish 1.375× BMR multiplier is the fallback until enough days of real data exist.

enum CalorieGoalKind: String, CaseIterable, Identifiable, Hashable {
    case cut, maintain, bulk
    var id: String { rawValue }

    var label: String {
        switch self {
        case .cut: return "Abnehmen"
        case .maintain: return "Halten"
        case .bulk: return "Muskelaufbau"
        }
    }

    /// Daily offset applied to TDEE. Cut: ~0.45 kg/week loss. Bulk: a conservative, lean surplus.
    var kcalOffset: Double {
        switch self {
        case .cut: return -500
        case .maintain: return 0
        case .bulk: return 300
        }
    }
}

enum CalorieTarget {
    /// Minimum days of real burned-calorie data before trusting the measured average over the
    /// fallback multiplier — a single unusual day (e.g. a rest day) shouldn't swing the target.
    static let minDaysForMeasuredTDEE = 3
    /// Fallback multiplier (BMR × this) when there isn't enough measured data yet — a lightly-active
    /// baseline, deliberately conservative rather than assuming a very active lifestyle.
    static let fallbackActivityMultiplier = 1.375

    /// `dailyBurns` are (BMR + active kcal) for each of the last few days that had usable data —
    /// pass however many are available; fewer than `minDaysForMeasuredTDEE` falls back to the
    /// multiplier.
    static func targetKcal(bmr: Double, recentDailyBurns: [Double], goal: CalorieGoalKind) -> Double {
        let tdee: Double
        if recentDailyBurns.count >= minDaysForMeasuredTDEE {
            tdee = recentDailyBurns.reduce(0, +) / Double(recentDailyBurns.count)
        } else {
            tdee = bmr * fallbackActivityMultiplier
        }
        return max(0, tdee + goal.kcalOffset)
    }

    /// Convenience: BMR from the profile via the shared `StrandAnalytics.Calories` formula.
    static func bmr(sex: String, weightKg: Double, heightCm: Double, age: Int) -> Double {
        Calories.dailyRestingKcal(sex: sex, weightKg: weightKg, heightCm: heightCm, age: Double(age))
    }
}
