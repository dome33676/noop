import Foundation
import WhoopStore

// MARK: - Manual weight entry — a user-logged value alongside Apple Health's synced series
//
// Weight (Health tile, "apple-health" source) had no write path at all: `MetricDetailView.load()` only
// ever read the "apple-health" device's own metricSeries rows. This gives the user a way to log a
// weight by hand, banked under its OWN device id in the SAME generic metricSeries table (no schema
// change) — so a manual point can never collide with an Apple Health import. Same key ("weight") is
// safe because `sourceId` already disambiguates the natural key (deviceId, day, key).
//
// Unlike `HydrationStore` (which ACCUMULATES taps into a running daily total), weight is a single daily
// scalar — a write here is a plain last-write-wins upsert, so a second entry for a day REPLACES the
// first rather than adding to it. That's the correct "edit" semantic for a scale reading.

enum ManualWeightStore {
    /// Its own local-only source id, distinct from "apple-health" — a manual entry can never be
    /// mistaken for (or collide with) a synced Health import.
    static let sourceId = "noop-manual-weight"

    /// metricSeries key. Same string Apple Health's own "weight" rows use — see the file comment above
    /// for why that's safe.
    static let key = "weight"
}

extension Repository {
    /// The user's hand-logged weight points, ascending by day. Thin wrapper over the generic
    /// metricSeries store, windowed the same way `series(key:source:days:fullHistory:)` is, so the
    /// merge in `MetricDetailView.load()` reads exactly the window the Apple Health series already did.
    func manualWeightSeries(days: Int = 4000, fullHistory: Bool = false) async -> [(day: String, value: Double)] {
        guard let store = await storeHandle() else { return [] }
        let now = Date()
        let from = fullHistory ? "0000-01-01" : Self.dayString(now.addingTimeInterval(-Double(days) * 86_400))
        let to = fullHistory ? "9999-12-31" : Self.dayString(now.addingTimeInterval(86_400))
        let pts = (try? await store.metricSeries(deviceId: ManualWeightStore.sourceId,
                                                  key: ManualWeightStore.key, from: from, to: to)) ?? []
        return pts.map { ($0.day, $0.value) }
    }

    /// Log (or replace) the manual weight for `day` (defaults to today's local day). Last-write-wins:
    /// a second entry for the same day overwrites the first — no read-before-write, since that IS the
    /// correct "edit" semantic for a daily scalar (unlike Hydration's accumulating taps).
    func logManualWeight(kg: Double, day: String? = nil) async {
        guard let store = await storeHandle() else { return }
        let dayKey = day ?? Repository.localDayKey(Date())
        _ = try? await store.upsertMetricSeries(
            [MetricPoint(day: dayKey, key: ManualWeightStore.key, value: kg)],
            deviceId: ManualWeightStore.sourceId)
    }
}
