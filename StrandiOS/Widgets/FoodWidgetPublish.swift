#if os(iOS)
import Foundation
import WidgetKit

/// Publishes today's per-meal-type eaten calories into the shared App Group for `NOOPFoodWidget`.
/// Called from `FoodView.reload()` whenever the visible day is today — the same choke point every
/// log/delete path already routes through, so this needs no extra call sites of its own.
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
        WidgetCenter.shared.reloadTimelines(ofKind: "NOOPFoodWidget")
    }
}
#endif
