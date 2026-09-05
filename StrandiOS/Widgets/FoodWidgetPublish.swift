#if os(iOS)
import Foundation
import WidgetKit

/// Publishes today's per-meal-type eaten calories into the shared App Group for `NOOPFoodWidget`.
/// Called from `FoodView.reload()` whenever the visible day is today — the same choke point every
/// log/delete path already routes through, so a meal log/delete needs no extra call site of its own.
/// `publishToday(repo:)` below covers the OTHER trigger: app foreground/background, independent of
/// whether Food is the visible tab.
enum FoodWidgetPublish {
    @MainActor
    static func publish(breakfastKcal: Double, lunchKcal: Double, dinnerKcal: Double,
                        snackKcal: Double, goalKcal: Double) {
        let next = FoodWidgetSnapshot(
            breakfastKcal: Int(breakfastKcal.rounded()),
            lunchKcal: Int(lunchKcal.rounded()),
            dinnerKcal: Int(dinnerKcal.rounded()),
            snackKcal: Int(snackKcal.rounded()),
            goalKcal: Int(goalKcal.rounded()),
            updated: Date()
        )
        guard FoodWidgetSnapshot.renderedContentChanged(from: FoodWidgetSnapshot.load(), to: next) else { return }
        next.save()
        WidgetCenter.shared.reloadAllTimelines()
    }

    /// Same publish, but computed directly from `repo` instead of a view's already-loaded state — for
    /// the app-foreground/background triggers in StrandiOSApp.swift, which (unlike FoodView.reload())
    /// run regardless of which tab is on screen. Without this, a widget added fresh (or surviving a
    /// reinstall's new App Group container) stayed on its all-zero ".unavailable" placeholder until the
    /// user happened to visit the Food tab at least once — the recovery widget has no such gap, since
    /// WidgetSnapshot.publish(from:) is called from those SAME scenePhase hooks, tab-independent.
    @MainActor
    static func publishToday(repo: Repository) async {
        let day = Repository.localDayKey(Date())
        let entries = await repo.mealEntries(day: day)
        let foodsById = Dictionary(uniqueKeysWithValues: await repo.foodItems().map { ($0.id, $0) })
        func kcal(_ type: FoodMealType) -> Double {
            entries.filter { $0.mealType == type.rawValue }.reduce(0.0) { acc, entry in
                guard let food = foodsById[entry.foodItemId] else { return acc }
                return acc + (entry.quantityGrams / 100.0) * (food.kcalPer100g ?? 0)
            }
        }
        // Mirrors FoodView's `@AppStorage("foodGoalKcal") private var goalKcal = 2000.0` default —
        // there's no SwiftUI environment here to read the property wrapper itself.
        let goalKcal = UserDefaults.standard.object(forKey: "foodGoalKcal") as? Double ?? 2000.0
        publish(breakfastKcal: kcal(.breakfast), lunchKcal: kcal(.lunch), dinnerKcal: kcal(.dinner),
                snackKcal: kcal(.snack), goalKcal: goalKcal)
    }
}
#endif
