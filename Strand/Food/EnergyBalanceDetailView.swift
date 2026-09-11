import SwiftUI
import StrandDesign
import WhoopStore

// MARK: - Energy Balance detail
//
// Pushed from Food's "ENERGY BALANCE" card (closure-based NavigationLink per #38 — see
// CoupledView's sleepCard, SettingsView's rows). Top to bottom: today's eaten/burned/deficit,
// a 7-day eaten-vs-burned trend, the week's total against the kcal goal, then the weight trend —
// reusing MetricDetailView's own manual-over-Apple-Health weight merge (MetricExplorerView.swift),
// not the full metric-explorer screen (day-cycle sky, correlation scan, readings table), which is
// too heavy to embed as a sub-section here.

struct EnergyBalanceDetailView: View {
    @EnvironmentObject var repo: Repository
    @EnvironmentObject var profile: ProfileStore

    @AppStorage("foodGoalKcal") private var goalKcal = 2000.0
    @AppStorage(UnitPrefs.systemKey) private var unitSystemRaw = UnitSystem.metric.rawValue
    private var unitSystem: UnitSystem { UnitSystem(rawValue: unitSystemRaw) ?? .metric }

    @State private var loaded = false
    /// Ascending, oldest first — 7 entries once loaded, today last.
    @State private var dailyPoints: [EnergyBalanceDayPoint] = []
    /// Manual-over-Apple-Health weight series, same priority MetricDetailView's "weight" merge uses.
    @State private var weightSeries: [(day: String, value: Double)] = []

    private var bmr: Double {
        CalorieTarget.bmr(sex: profile.sex, weightKg: profile.weightKg, heightCm: profile.heightCm, age: profile.age)
    }

    private var todayPoint: EnergyBalanceDayPoint? { dailyPoints.last }
    private var todayEaten: Double { todayPoint?.eatenKcal ?? 0 }
    private var todayBurned: Double { todayPoint?.burnedKcal ?? 0 }
    private var todayBalance: Double { todayBurned - todayEaten }

    private var weeklyEaten: Double { dailyPoints.reduce(0) { $0 + $1.eatenKcal } }
    private var weeklyGoal: Double { goalKcal * 7 }
    /// Goal minus actual eaten over the week — positive = ate under the weekly budget ("deficit"),
    /// negative = over it ("overhead"). Deliberately vs. the GOAL, not vs. burned — a different shape
    /// than `EnergyBalance.dailyBalance`'s true burned-vs-eaten balance on the daily card above.
    private var weeklyDelta: Double { weeklyGoal - weeklyEaten }

    var body: some View {
        ScreenScaffold(title: "Energy Balance", subtitle: "Eaten vs. burned, over the week.") {
            VStack(alignment: .leading, spacing: NoopMetrics.sectionGap) {
                todaySection
                if loaded && !dailyPoints.isEmpty { weekChartSection }
                weeklyGoalSection
                if loaded && !weightSeries.isEmpty { weightSection }
            }
        }
        .task(id: repo.refreshSeq) { await load() }
    }

    // MARK: - Today's numbers

    private var todaySection: some View {
        // Same adaptive 3-up grid MetricExplorerView's statRow uses for its StatTile row.
        LazyVGrid(
            columns: [GridItem(.adaptive(minimum: 100), spacing: NoopMetrics.gap)],
            alignment: .leading,
            spacing: NoopMetrics.gap
        ) {
            StatTile(label: "Eaten", value: "\(Int(todayEaten.rounded())) kcal", accent: StrandPalette.metricAmber)
            StatTile(label: "Burned", value: "\(Int(todayBurned.rounded())) kcal", accent: StrandPalette.metricCyan)
            StatTile(label: todayBalance >= 0 ? "Deficit" : "Surplus",
                     value: "\(Int(abs(todayBalance).rounded())) kcal",
                     accent: todayBalance >= 0 ? StrandPalette.statusPositive : StrandPalette.statusWarning)
        }
    }

    // MARK: - Weekly eaten-vs-burned chart

    private var weekChartSection: some View {
        ChartCard(title: "This week", subtitle: "Eaten vs. burned · last 7 days", tint: StrandPalette.metricAmber) {
            EnergyBalanceWeekChart(points: dailyPoints)
        } footer: {
            HStack(spacing: 16) {
                legendDot("Eaten", color: StrandPalette.metricAmber)
                legendDot("Burned", color: StrandPalette.metricCyan)
            }
        }
    }

    private func legendDot(_ label: LocalizedStringKey, color: Color) -> some View {
        HStack(spacing: 5) {
            Circle().fill(color).frame(width: 8, height: 8)
            Text(label).font(StrandFont.footnote).foregroundStyle(StrandPalette.textSecondary)
        }
    }

    // MARK: - Weekly goal

    private var weeklyGoalSection: some View {
        let isDeficit = weeklyDelta >= 0
        let color = isDeficit ? StrandPalette.statusPositive : StrandPalette.statusWarning
        return NoopCard {
            VStack(alignment: .leading, spacing: NoopMetrics.gap) {
                Text("VS. YOUR WEEKLY GOAL").strandOverline()
                HStack {
                    Text("\(Int(weeklyEaten.rounded())) / \(Int(weeklyGoal.rounded())) kcal eaten")
                        .font(StrandFont.subhead)
                        .foregroundStyle(StrandPalette.textSecondary)
                    Spacer(minLength: 8)
                    Text(isDeficit ? "−\(Int(weeklyDelta.rounded())) kcal deficit" : "+\(Int((-weeklyDelta).rounded())) kcal overhead")
                        .font(StrandFont.subhead.weight(.semibold))
                        .foregroundStyle(color)
                }
                PipBar(value: weeklyEaten, range: 0...max(weeklyGoal, weeklyEaten, 1), segments: 20, tint: color, height: 7)
            }
        }
    }

    // MARK: - Weight (reuses MetricDetailView's manual-over-Apple-Health merge + ChartCard/TrendChart)

    @ViewBuilder private var weightSection: some View {
        let trendPoints: [TrendPoint] = weightSeries.compactMap { row in
            guard let d = Self.weightDayParser.date(from: row.day) else { return nil }
            return TrendPoint(date: d, value: row.value)
        }
        let values = weightSeries.map(\.value)
        ChartCard(title: "Weight",
                  subtitle: weightSeries.count == 1
                    ? String(localized: "1 reading") : String(localized: "\(weightSeries.count) readings"),
                  trailing: weightSeries.last.map { UnitFormatter.massFromKilograms($0.value, system: unitSystem) },
                  tint: StrandPalette.metricCyan) {
            TrendChart(
                points: trendPoints,
                gradient: Gradient(colors: [StrandPalette.metricCyan.opacity(0.55), StrandPalette.metricCyan]),
                valueRange: Self.paddedValueRange(values),
                showsArea: true,
                valueFormat: { UnitFormatter.massFromKilograms($0, system: unitSystem) }
            )
        }
    }

    /// UTC/en_US_POSIX "yyyy-MM-dd" parser — matches MetricExplorerView's own `strandDayParser`, the
    /// convention the weight series this reuses was built against.
    private static let weightDayParser: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(identifier: "UTC")
        f.dateFormat = "yyyy-MM-dd"
        return f
    }()

    /// Padded value range so the line never sits flush against an axis — same padding
    /// MetricExplorerView's `valueRange` uses.
    private static func paddedValueRange(_ values: [Double]) -> ClosedRange<Double> {
        guard let lo = values.min(), let hi = values.max() else { return 0...1 }
        if hi <= lo { return (lo - 1)...(hi + 1) }
        let span = hi - lo
        return (lo - span * 0.12)...(hi + span * 0.12)
    }

    // MARK: - Data

    /// Builds the 7-day eaten/burned series from meal entries + Apple Health's daily active-kcal
    /// (same math as `FoodView.totals`/`reloadEnergyData`, no new Repository accessor needed), and the
    /// weight series from `repo.exploreSeries` + `repo.manualWeightSeries()` (MetricExplorerView's own
    /// merge, manual entry overriding Apple Health for a shared day).
    private func load() async {
        async let libraryTask = repo.foodItems()
        async let appleTask = repo.appleDailyRows(days: 10)
        async let weightAppleTask = repo.exploreSeries(key: "weight", source: "apple-health")
        async let weightManualTask = repo.manualWeightSeries()

        let foodsById = Dictionary(uniqueKeysWithValues: await libraryTask.map { ($0.id, $0) })
        var activeByDay: [String: Double] = [:]
        for row in await appleTask where row.activeKcal != nil { activeByDay[row.day] = row.activeKcal }
        // Apple Health's own measured `.basalEnergyBurned` per day, preferred over the formula-based
        // `bmr` below wherever it's available — real data beats a static estimate for a complete PAST
        // day too, and for TODAY specifically it's the live so-far read (see FoodView's identical fix).
        var basalByDay: [String: Double] = [:]
        for row in await appleTask where row.basalKcal != nil { basalByDay[row.day] = row.basalKcal }

        let bmrValue = bmr
        let todayDate = Date()
        var built: [EnergyBalanceDayPoint] = []
        for offset in stride(from: 6, through: 0, by: -1) {
            let date = Calendar.current.date(byAdding: .day, value: -offset, to: todayDate) ?? todayDate
            let day = Repository.localDayKey(date)
            let entries = await repo.mealEntries(day: day)
            let eaten = entries.reduce(0.0) { acc, entry in
                guard let food = foodsById[entry.foodItemId] else { return acc }
                return acc + (food.kcalPer100g ?? 0) * entry.quantityGrams / 100.0
            }
            let burned = (basalByDay[day] ?? bmrValue) + (activeByDay[day] ?? 0)
            built.append(EnergyBalanceDayPoint(day: day, date: date, eatenKcal: eaten, burnedKcal: burned))
        }
        dailyPoints = built

        var weightByDay = Dictionary(await weightAppleTask.map { ($0.day, $0.value) },
                                     uniquingKeysWith: { first, _ in first })
        for point in await weightManualTask { weightByDay[point.day] = point.value }
        weightSeries = weightByDay.sorted { $0.key < $1.key }.map { (day: $0.key, value: $0.value) }

        loaded = true
    }
}
