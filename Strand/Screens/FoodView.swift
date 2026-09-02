import SwiftUI
import StrandDesign
import WhoopStore
import StrandAnalytics

// MARK: - Food tab
//
// A day-diary over the food library: a liquid ring for calories eaten vs. a goal-derived target
// (mirrors `HydrationView`'s `LiquidVessel` + `CountUpText` hero — "current vs. goal", the same
// shape hydration already uses, not a 0-100 score like Sleep's `LiquidScoreGauge`), macro bars via
// the shared `PipBarRow`, a daily energy-balance card with a 7-day bar chart, then meals grouped by
// type. Entries are resolved against the food library client-side (loaded once per reload) so the
// totals shown always match the rows shown beneath them, with no second read that could disagree.

struct FoodView: View {
    @EnvironmentObject var repo: Repository
    @EnvironmentObject var profile: ProfileStore

    @State private var dayOffset = 0
    @State private var entries: [MealEntryRow] = []
    @State private var foodsById: [String: FoodItemRow] = [:]
    @State private var loaded = false

    @State private var showLogSheet = false
    @State private var editingEntry: MealEntryRow?
    @State private var quickAddMealType: FoodMealType?
    @State private var expandedMealType: FoodMealType?

    @AppStorage("foodGoalKcal") private var goalKcal = 2000.0
    @AppStorage("foodGoalProteinG") private var goalProtein = 150.0
    @AppStorage("foodGoalCarbsG") private var goalCarbs = 250.0
    @AppStorage("foodGoalFatG") private var goalFat = 70.0

    @State private var heroFraction: Double = 0
    /// (BMR + active kcal) for each of the last few PAST days that had Apple Health active-kcal data
    /// — the measured-TDEE input for `CalorieTarget`. Empty until enough days accumulate.
    @State private var recentDailyBurns: [Double] = []
    @State private var weeklyBalance: [EnergyBalanceDay] = []
    @State private var todayActiveKcal: Double = 0

    private var today: Date { Date() }
    private var day: String {
        Repository.localDayKey(Calendar.current.date(byAdding: .day, value: -dayOffset, to: today) ?? today)
    }
    private var bmr: Double {
        CalorieTarget.bmr(sex: profile.sex, weightKg: profile.weightKg, heightCm: profile.heightCm, age: profile.age)
    }
    private var fraction: Double { goalKcal > 0 ? min(1.0, max(0.0, totals.kcal / goalKcal)) : 0 }
    private var todayBalance: Double {
        EnergyBalance.dailyBalance(bmr: bmr, activeKcal: todayActiveKcal, eatenKcal: totals.kcal)
    }

    var body: some View {
        ScreenScaffold(title: "Food", subtitle: "Your meals, on this device only.",
                       onRefresh: { await reload() }) {
            VStack(alignment: .leading, spacing: NoopMetrics.sectionGap) {
                DayNavBar(selectedOffset: dayOffset, today: today) { newOffset in
                    dayOffset = newOffset
                    Task { await reload() }
                }
                heroSection
                if dayOffset == 0 { energyBalanceSection }
                mealsSection
            }
            .onChangeCompat(of: fraction) { newFraction in
                withAnimation(.easeOut(duration: 0.9)) { heroFraction = newFraction }
            }
            .onAppear {
                withAnimation(.easeOut(duration: 0.9)) { heroFraction = fraction }
            }
        }
        // Pinned above the tab bar, overlaid into the bottom scroll clearance `ScreenScaffold`
        // already reserves (`NoopMetrics.tabBarClearance`) rather than via `.safeAreaInset`, which
        // this app's native `TabView` doesn't propagate safe-area insets through correctly.
        .overlay(alignment: .bottom) {
            logMealButton
        }
        .task(id: dayOffset) { await reload() }
        .sheet(isPresented: $showLogSheet) {
            LogMealSheet(day: day) { entry in
                Task { await repo.logMeal(entry); await reload() }
            }
        }
        .sheet(item: $editingEntry) { entry in
            LogMealSheet(editing: entry, initialFood: foodsById[entry.foodItemId], day: day) { updated in
                Task { await repo.logMeal(updated); await reload() }
            }
        }
        .sheet(item: $quickAddMealType) { type in
            LogMealSheet(presetMealType: type, day: day) { entry in
                Task { await repo.logMeal(entry); await reload() }
            }
        }
    }

    // MARK: - Floating "Log meal" (pinned above the tab bar)

    private var logMealButton: some View {
        NoopButton("Log meal", systemImage: "plus", kind: .primary, fullWidth: true) {
            showLogSheet = true
        }
        .padding(.horizontal, NoopMetrics.screenHPadding)
        .padding(.bottom, 8)
    }

    // MARK: - Hero (eaten / ring+remaining / burned, plus macro bars)

    private var heroSection: some View {
        NoopCard {
            VStack(spacing: NoopMetrics.space5) {
                HStack(spacing: 0) {
                    heroStat(value: totals.kcal, label: "Eaten")
                    Spacer(minLength: 0)
                    ZStack {
                        LiquidVessel(value: heroFraction, tint: StrandPalette.metricAmber, animated: true)
                            .frame(width: 148, height: 148)
                        VStack(spacing: 2) {
                            CountUpText(value: max(0, goalKcal - totals.kcal),
                                        format: { String(Int($0.rounded())) },
                                        font: StrandFont.rounded(32, weight: .bold),
                                        color: StrandPalette.textPrimary)
                                .shadow(color: .black.opacity(0.5), radius: 6, y: 1)
                            Text("Remaining")
                                .font(StrandFont.footnote)
                                .foregroundStyle(StrandPalette.textSecondary)
                        }
                        .allowsHitTesting(false)
                    }
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel("Calories remaining")
                    .accessibilityValue("\(Int(max(0, goalKcal - totals.kcal).rounded())) of \(Int(goalKcal)) kcal")
                    Spacer(minLength: 0)
                    heroStat(value: todayActiveKcal, label: "Burned")
                }
                HStack(alignment: .top, spacing: NoopMetrics.space5) {
                    macroColumn(label: "Protein", value: totals.protein, goal: goalProtein, tint: StrandPalette.textPrimary)
                    macroColumn(label: "Carbs", value: totals.carbs, goal: goalCarbs, tint: StrandPalette.metricCyan)
                    macroColumn(label: "Fat", value: totals.fat, goal: goalFat, tint: StrandPalette.effortColor)
                }
            }
        }
    }

    private func heroStat(value: Double, label: String) -> some View {
        VStack(spacing: 2) {
            Text("\(Int(value.rounded()))")
                .font(StrandFont.title2)
                .foregroundStyle(StrandPalette.textPrimary)
                .monospacedDigit()
            Text(label)
                .font(StrandFont.footnote)
                .foregroundStyle(StrandPalette.textSecondary)
        }
    }

    private func macroColumn(label: String, value: Double, goal: Double, tint: Color) -> some View {
        VStack(spacing: 6) {
            Text(label)
                .font(StrandFont.footnote)
                .foregroundStyle(StrandPalette.textSecondary)
            PipBar(value: value, range: 0...max(goal, value, 1), segments: 20, tint: tint, height: 7)
            Text("\(Int(value.rounded())) / \(Int(goal)) g")
                .font(StrandFont.footnote)
                .foregroundStyle(StrandPalette.textTertiary)
        }
        .frame(maxWidth: .infinity)
    }

    // MARK: - Energy balance (today's actual deficit/surplus + 7-day chart)

    private var energyBalanceSection: some View {
        let isDeficit = todayBalance >= 0
        let color = isDeficit ? StrandPalette.statusPositive : StrandPalette.statusWarning
        return ChartCard(
            title: "ENERGY BALANCE",
            subtitle: "Resting + active burn, minus what you ate",
            tint: color
        ) {
            if weeklyBalance.count >= 2 {
                let values = weeklyBalance.map(\.balanceKcal)
                let lo = min(0, values.min() ?? 0) - 100
                let hi = max(0, values.max() ?? 0) + 100
                TrendChart(
                    points: weeklyBalance.map { TrendPoint(date: $0.date, value: $0.balanceKcal) },
                    gradient: Gradient(colors: [color.opacity(0.5), color]),
                    valueRange: lo...hi,
                    showsArea: false,
                    showsBars: true,
                    valueFormat: { String(Int($0.rounded())) + " kcal" }
                )
            } else {
                Text("Not enough data yet for a weekly view.")
                    .font(StrandFont.footnote)
                    .foregroundStyle(StrandPalette.textTertiary)
            }
        } footer: {
            ChartFooter([
                ("Today", isDeficit ? "−\(Int(todayBalance.rounded())) kcal saved" : "+\(Int((-todayBalance).rounded())) kcal over"),
            ])
        }
    }

    // MARK: - Meals grouped by type

    @ViewBuilder private var mealsSection: some View {
        Text("Nutrition").strandOverline()
        NoopCard {
            VStack(spacing: 0) {
                ForEach(Array(FoodMealType.allCases.enumerated()), id: \.element.id) { idx, type in
                    mealTypeRow(type)
                    if idx < FoodMealType.allCases.count - 1 { Divider().opacity(0.4) }
                }
            }
        }
        if loaded && entries.isEmpty {
            NoopCard {
                Text("No meals logged for this day yet.")
                    .font(StrandFont.subhead)
                    .foregroundStyle(StrandPalette.textSecondary)
            }
        }
    }

    private func mealTypeRow(_ type: FoodMealType) -> some View {
        let rows = entries.filter { $0.mealType == type.rawValue }
        let eaten = eatenKcal(for: type)
        let allocated = allocatedKcal(for: type)
        let fraction = allocated > 0 ? min(1.0, max(0.0, eaten / allocated)) : 0
        let preview = rows.compactMap { foodsById[$0.foodItemId]?.name }.joined(separator: ", ")
        let isExpanded = expandedMealType == type
        return VStack(spacing: 0) {
            HStack(spacing: 12) {
                Button {
                    withAnimation(.easeOut(duration: 0.2)) {
                        expandedMealType = isExpanded ? nil : type
                    }
                } label: {
                    HStack(spacing: 12) {
                        mealTypeRing(fraction: fraction, icon: type.icon)
                        VStack(alignment: .leading, spacing: 2) {
                            HStack(spacing: 4) {
                                Text(type.label)
                                    .font(StrandFont.subhead)
                                    .foregroundStyle(StrandPalette.textPrimary)
                                Image(systemName: "chevron.right")
                                    .font(.system(size: 11, weight: .semibold))
                                    .foregroundStyle(StrandPalette.textTertiary)
                                    .rotationEffect(.degrees(isExpanded ? 90 : 0))
                            }
                            Text("\(Int(eaten.rounded())) / \(Int(allocated.rounded())) kcal")
                                .font(StrandFont.footnote)
                                .foregroundStyle(StrandPalette.textTertiary)
                            if !preview.isEmpty {
                                Text(preview)
                                    .font(StrandFont.footnote)
                                    .foregroundStyle(StrandPalette.textTertiary)
                                    .lineLimit(1)
                            }
                        }
                        Spacer(minLength: 8)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                Button {
                    quickAddMealType = type
                } label: {
                    Image(systemName: "plus")
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(StrandPalette.accent)
                        .frame(width: 32, height: 32)
                        .background(StrandPalette.surfaceInset, in: Circle())
                }
                .buttonStyle(.plain)
            }
            .padding(.vertical, 8)
            if isExpanded && !rows.isEmpty {
                VStack(spacing: 0) {
                    ForEach(Array(rows.enumerated()), id: \.element.id) { idx, entry in
                        entryRow(entry)
                        if idx < rows.count - 1 { Divider().opacity(0.4) }
                    }
                }
                .padding(.leading, 56)
                .padding(.bottom, 8)
            }
        }
    }

    /// Small circular progress ring (eaten / allocated kcal for one meal type) with its SF Symbol
    /// icon centered inside — a lighter-weight sibling of `LiquidVessel`, sized for a list row.
    private func mealTypeRing(fraction: Double, icon: String) -> some View {
        ZStack {
            Circle()
                .stroke(StrandPalette.surfaceInset, lineWidth: 3)
            Circle()
                .trim(from: 0, to: max(0.0001, fraction))
                .stroke(StrandPalette.accent, style: StrokeStyle(lineWidth: 3, lineCap: .round))
                .rotationEffect(.degrees(-90))
            Image(systemName: icon)
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(StrandPalette.accent)
        }
        .frame(width: 44, height: 44)
    }

    /// Fixed percentage split of the daily calorie goal across meal types (breakfast/lunch/dinner
    /// biggest, snack smallest) — used only as the denominator for each meal type's mini-ring.
    private func allocatedKcal(for type: FoodMealType) -> Double {
        let ratio: Double
        switch type {
        case .breakfast: ratio = 0.30
        case .lunch: ratio = 0.40
        case .dinner: ratio = 0.25
        case .snack: ratio = 0.05
        }
        return goalKcal * ratio
    }

    private func eatenKcal(for type: FoodMealType) -> Double {
        entries.filter { $0.mealType == type.rawValue }.reduce(0.0) { acc, entry in
            guard let food = foodsById[entry.foodItemId] else { return acc }
            return acc + (food.kcalPer100g ?? 0) * entry.quantityGrams / 100.0
        }
    }

    private func entryRow(_ entry: MealEntryRow) -> some View {
        let food = foodsById[entry.foodItemId]
        let kcal = food.map { ($0.kcalPer100g ?? 0) * entry.quantityGrams / 100.0 }
        return HStack(spacing: 10) {
            Button { editingEntry = entry } label: {
                HStack(spacing: 10) {
                    VStack(alignment: .leading, spacing: 1) {
                        Text(food?.name ?? "Unknown food")
                            .font(StrandFont.subhead)
                            .foregroundStyle(StrandPalette.textPrimary)
                        Text("\(Int(entry.quantityGrams.rounded()))g")
                            .font(StrandFont.footnote)
                            .foregroundStyle(StrandPalette.textTertiary)
                    }
                    Spacer(minLength: 8)
                    if let kcal {
                        Text("\(Int(kcal.rounded())) kcal")
                            .font(StrandFont.subhead.weight(.semibold))
                            .foregroundStyle(StrandPalette.textPrimary)
                            .monospacedDigit()
                    }
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            Button(role: .destructive) {
                Task { await repo.deleteMealEntry(id: entry.id); await reload() }
            } label: {
                Image(systemName: "trash")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(StrandPalette.textTertiary)
                    .frame(width: 36, height: 36)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        }
        .padding(.vertical, 6)
    }

    // MARK: - Totals

    private var totals: (kcal: Double, protein: Double, carbs: Double, fat: Double) {
        entries.reduce((0.0, 0.0, 0.0, 0.0)) { acc, entry in
            guard let food = foodsById[entry.foodItemId] else { return acc }
            let scale = entry.quantityGrams / 100.0
            return (
                acc.0 + scale * (food.kcalPer100g ?? 0),
                acc.1 + scale * (food.proteinPer100g ?? 0),
                acc.2 + scale * (food.carbsPer100g ?? 0),
                acc.3 + scale * (food.fatPer100g ?? 0)
            )
        }
    }

    // MARK: - Data

    private func reload() async {
        let day = self.day
        async let entriesTask = repo.mealEntries(day: day)
        async let libraryTask = repo.foodItems()
        entries = await entriesTask
        let library = await libraryTask
        foodsById = Dictionary(uniqueKeysWithValues: library.map { ($0.id, $0) })
        loaded = true
        if dayOffset == 0 { await reloadEnergyData() }
    }

    /// Builds the measured-TDEE input, today's active kcal, and the 7-day balance series from Apple
    /// Health's daily aggregates + the food log's projected daily totals — both already keyed by the
    /// same `yyyy-MM-dd` local-day string (`Repository.dayString`/`localDayKey` share one format).
    private func reloadEnergyData() async {
        async let appleDailyTask = repo.appleDailyRows(days: 10)
        async let eatenTask = repo.foodMetricSeries(key: "food_calories_in_kcal", days: 10)
        let appleDaily = await appleDailyTask
        let eaten = await eatenTask

        var activeByDay: [String: Double] = [:]
        for row in appleDaily where row.activeKcal != nil { activeByDay[row.day] = row.activeKcal }
        let eatenByDay = Dictionary(uniqueKeysWithValues: eaten.map { ($0.day, $0.value) })

        let todayKey = Repository.localDayKey(Date())
        todayActiveKcal = activeByDay[todayKey] ?? 0

        let bmrValue = bmr
        let pastDaysWithData = activeByDay.keys.filter { $0 != todayKey }.sorted().suffix(7)
        recentDailyBurns = pastDaysWithData.compactMap { activeByDay[$0] }.map { bmrValue + $0 }

        var series: [EnergyBalanceDay] = []
        for offset in stride(from: 6, through: 0, by: -1) {
            guard let date = Calendar.current.date(byAdding: .day, value: -offset, to: Date()) else { continue }
            let key = Repository.localDayKey(date)
            let balance = EnergyBalance.dailyBalance(
                bmr: bmrValue, activeKcal: activeByDay[key] ?? 0, eatenKcal: eatenByDay[key] ?? 0)
            series.append(EnergyBalanceDay(day: key, date: date, balanceKcal: balance))
        }
        weeklyBalance = series
    }
}
