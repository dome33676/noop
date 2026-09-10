import Foundation
import WhoopStore

// MARK: - Custom food portion (app-layer JSON shape for `foodItem.customPortionsJSON`)
//
// WhoopStore stores `customPortionsJSON` as a plain String (matching the `strengthTemplate.planJSON`
// convention: a structured sub-shape that's always read/written as a whole doesn't need its own
// table). This file owns the actual shape + encode/decode, keeping WhoopStore storage-agnostic about
// what's inside.

/// One user-defined portion preset — e.g. "Meine Portion" at 250g, ADDITIVE to whatever
/// `FoodItemRow.servingSizeG` an Open Food Facts scan filled in. Lets a food the user eats in a
/// consistent amount (not necessarily the scanned default) skip typing grams every time.
struct FoodPortion: Codable, Equatable, Identifiable {
    var label: String
    var grams: Double
    var id: String { label }
}

extension FoodItemRow {
    /// Decode `customPortionsJSON`. Malformed/legacy/absent JSON decodes to an empty list rather than
    /// throwing — a food item with no custom presets is the common case, not an error.
    var customPortions: [FoodPortion] {
        guard let json = customPortionsJSON else { return [] }
        return (try? JSONDecoder().decode([FoodPortion].self, from: Data(json.utf8))) ?? []
    }

    static func encodePortions(_ portions: [FoodPortion]) -> String {
        (try? String(data: JSONEncoder().encode(portions), encoding: .utf8)) ?? "[]"
    }
}
