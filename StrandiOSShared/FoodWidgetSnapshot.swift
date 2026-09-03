import Foundation

/// Small, Codable glance snapshot of today's per-meal-type calories, shared between the iOS app and
/// its widget extension via the same App Group `WidgetSnapshot` uses. Kept as its OWN struct/storage
/// key rather than folded into `WidgetSnapshot`: food updates on a completely different trigger (a
/// meal logged or deleted) than the recovery/BLE fields, and mixing the two would mean every meal log
/// rewrites and re-renders the recovery widget family too.
public struct FoodWidgetSnapshot: Codable, Equatable {
    public var breakfastKcal: Int
    public var lunchKcal: Int
    public var dinnerKcal: Int
    public var snackKcal: Int
    /// The user's daily calorie goal at publish time, so the widget can show "eaten / goal" without
    /// reading `@AppStorage` itself (outside the App Group, same reasoning as `WidgetSnapshot.effortDisplay`).
    public var goalKcal: Int
    public var updated: Date

    public init(breakfastKcal: Int, lunchKcal: Int, dinnerKcal: Int, snackKcal: Int, goalKcal: Int, updated: Date) {
        self.breakfastKcal = breakfastKcal
        self.lunchKcal = lunchKcal
        self.dinnerKcal = dinnerKcal
        self.snackKcal = snackKcal
        self.goalKcal = goalKcal
        self.updated = updated
    }

    public static let storageKey = "noop.widget.food.snapshot"

    public static var placeholder: FoodWidgetSnapshot {
        FoodWidgetSnapshot(breakfastKcal: 320, lunchKcal: 540, dinnerKcal: 0, snackKcal: 90, goalKcal: 2000, updated: Date())
    }

    /// Honest runtime state when the app has not published a readable snapshot yet.
    public static var unavailable: FoodWidgetSnapshot {
        FoodWidgetSnapshot(breakfastKcal: 0, lunchKcal: 0, dinnerKcal: 0, snackKcal: 0, goalKcal: 0, updated: .distantPast)
    }

    public static func load() -> FoodWidgetSnapshot? {
        guard let defaults = UserDefaults(suiteName: WidgetSnapshot.suiteName),
              let data = defaults.data(forKey: storageKey),
              let snap = try? JSONDecoder().decode(FoodWidgetSnapshot.self, from: data) else { return nil }
        return snap
    }

    public func save() {
        guard let defaults = UserDefaults(suiteName: WidgetSnapshot.suiteName),
              let data = try? JSONEncoder().encode(self) else { return }
        defaults.set(data, forKey: FoodWidgetSnapshot.storageKey)
    }

    /// Whether publishing `next` would change anything the widget actually renders. `updated` is
    /// excluded for the same reason `WidgetSnapshot` excludes it: no widget family displays it, and an
    /// otherwise-identical publish should be a true no-op, not an App-Group write plus a reload.
    public static func renderedContentChanged(from previous: FoodWidgetSnapshot?, to next: FoodWidgetSnapshot) -> Bool {
        guard let previous else { return true }
        return previous.breakfastKcal != next.breakfastKcal
            || previous.lunchKcal != next.lunchKcal
            || previous.dinnerKcal != next.dinnerKcal
            || previous.snackKcal != next.snackKcal
            || previous.goalKcal != next.goalKcal
    }
}
