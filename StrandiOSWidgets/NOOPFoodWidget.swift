import WidgetKit
import SwiftUI
import StrandDesign

/// Timeline entry backed by the latest `FoodWidgetSnapshot` the app published into the App Group.
struct FoodEntry: TimelineEntry {
    let date: Date
    let snapshot: FoodWidgetSnapshot
}

struct FoodProvider: TimelineProvider {
    func placeholder(in context: Context) -> FoodEntry {
        FoodEntry(date: Date(), snapshot: .placeholder)
    }

    func getSnapshot(in context: Context, completion: @escaping (FoodEntry) -> Void) {
        let fallback: FoodWidgetSnapshot = context.isPreview ? .placeholder : .unavailable
        completion(FoodEntry(date: Date(), snapshot: FoodWidgetSnapshot.load() ?? fallback))
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<FoodEntry>) -> Void) {
        let snap = FoodWidgetSnapshot.load() ?? .unavailable
        // Meal totals only change when the app publishes a fresh snapshot (a meal logged or deleted),
        // which forces its own reload — this periodic refresh exists only to catch the midnight
        // rollover to a new, empty day even if nothing gets logged right at midnight.
        let next = Calendar.current.nextDate(after: Date(), matching: DateComponents(hour: 0, minute: 5),
                                              matchingPolicy: .nextTime) ?? Date().addingTimeInterval(3600)
        completion(Timeline(entries: [FoodEntry(date: Date(), snapshot: snap)], policy: .after(next)))
    }
}

/// Today's calories by meal, with a per-meal quick-add. Tapping a meal slot opens NOOP straight into
/// the log sheet for that meal (`noop://log-meal?type=...`) rather than logging in place — the widget
/// stays read-only/deep-link-only, matching every other NOOP widget family.
struct NOOPFoodWidgetView: View {
    @Environment(\.widgetFamily) private var family
    let entry: FoodEntry

    private var snap: FoodWidgetSnapshot { entry.snapshot }
    private var eatenTotal: Int { snap.breakfastKcal + snap.lunchKcal + snap.dinnerKcal + snap.snackKcal }
    private var remaining: Int { max(0, snap.goalKcal - eatenTotal) }

    var body: some View {
        switch family {
        case .systemMedium:
            medium
        default:
            small
        }
    }

    // MARK: - systemSmall: just the headline number

    private var small: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 4) {
                Image(systemName: "fork.knife")
                    .font(.system(size: 11, weight: .bold))
                Text("FOOD")
                    .font(.system(size: 11, weight: .bold))
            }
            .foregroundStyle(StrandPalette.textSecondary)
            Spacer(minLength: 0)
            Text("\(remaining)")
                .font(.system(size: 32, weight: .bold, design: .rounded))
                .foregroundStyle(StrandPalette.textPrimary)
                .monospacedDigit()
                .minimumScaleFactor(0.6)
                .lineLimit(1)
            Text("kcal left")
                .font(.caption2)
                .foregroundStyle(StrandPalette.textTertiary)
            Spacer(minLength: 0)
            Text("\(eatenTotal) eaten today")
                .font(.caption2)
                .foregroundStyle(StrandPalette.textSecondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .widgetURL(URL(string: "noop://log-meal"))
    }

    // MARK: - systemMedium: 4 meal slots, each its own tap target

    private var medium: some View {
        HStack(spacing: 0) {
            mealSlot(label: "Breakfast", icon: "sunrise", kcal: snap.breakfastKcal, type: "breakfast")
            divider
            mealSlot(label: "Lunch", icon: "sun.max", kcal: snap.lunchKcal, type: "lunch")
            divider
            mealSlot(label: "Dinner", icon: "moon", kcal: snap.dinnerKcal, type: "dinner")
            divider
            mealSlot(label: "Snack", icon: "leaf", kcal: snap.snackKcal, type: "snack")
        }
        .padding(.vertical, 12)
    }

    private var divider: some View {
        Rectangle()
            .fill(StrandPalette.hairline)
            .frame(width: 1)
            .padding(.vertical, 10)
    }

    /// One meal's ring + kcal + quick-add, as its own `Link` — WidgetKit supports multiple distinct
    /// tap targets per widget via `Link`, so each slot deep-links to a DIFFERENT preset meal type
    /// instead of the whole widget sharing one `widgetURL`.
    private func mealSlot(label: String, icon: String, kcal: Int, type: String) -> some View {
        Link(destination: mealLink(type)) {
            VStack(spacing: 6) {
                ZStack {
                    Circle()
                        .stroke(StrandPalette.textPrimary.opacity(0.12), lineWidth: 2)
                        .frame(width: 42, height: 42)
                    Image(systemName: icon)
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(StrandPalette.accent)
                }
                Text("\(kcal) kcal")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(StrandPalette.textPrimary)
                    .monospacedDigit()
                    .minimumScaleFactor(0.7)
                    .lineLimit(1)
                Image(systemName: "plus.circle.fill")
                    .font(.system(size: 18))
                    .foregroundStyle(.white, StrandPalette.accent)
            }
            .frame(maxWidth: .infinity)
            .contentShape(Rectangle())
        }
        .accessibilityLabel(Text("\(label), \(kcal) kilocalories logged. Add food."))
    }

    private func mealLink(_ type: String) -> URL {
        var components = URLComponents()
        components.scheme = "noop"
        components.host = "log-meal"
        components.queryItems = [URLQueryItem(name: "type", value: type)]
        return components.url ?? URL(string: "noop://log-meal")!
    }
}

struct NOOPFoodWidget: Widget {
    let kind = "NOOPFoodWidget"

    var body: some WidgetConfiguration {
        StaticConfiguration(kind: kind, provider: FoodProvider()) { entry in
            NOOPFoodWidgetView(entry: entry)
                .containerBackground(StrandPalette.surfaceBase, for: .widget)
        }
        .configurationDisplayName("NOOP Food")
        .description("Today's calories by meal, with quick-add.")
        .supportedFamilies([.systemSmall, .systemMedium])
    }
}
