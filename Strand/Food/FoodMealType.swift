import SwiftUI

/// The four meal slots a `MealEntryRow.mealType` can hold. Stored as the raw string in WhoopStore
/// (matching the flat, string-typed convention `sport`/`source` already use on `workout`), classified
/// back into this enum at the app layer for display/grouping.
enum FoodMealType: String, CaseIterable, Identifiable, Hashable {
    case breakfast, lunch, dinner, snack

    var id: String { rawValue }

    var label: String {
        switch self {
        case .breakfast: "Breakfast"
        case .lunch: "Lunch"
        case .dinner: "Dinner"
        case .snack: "Snack"
        }
    }

    var icon: String {
        switch self {
        case .breakfast: "sunrise"
        case .lunch: "sun.max"
        case .dinner: "moon"
        case .snack: "leaf"
        }
    }
}
