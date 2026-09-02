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
    @State private var showGoalsSheet = false

    @AppStorage("foodGoalKcal") private var goalKcal = 2000.0
    @AppStorage("foodGoalProteinG") private var goalProtein = 150.0
    @AppStorage("foodGoalCarbsG") private var goalCarbs = 250.0
    @AppStorage("foodGoalFatG") private var goalFat = 70.0
    @AppStorage("foodGoalKind") private var goalKindRaw = CalorieGoalKind.maintain.rawValue

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
    private var goalKind: CalorieGoalKind { CalorieGoalKind(rawValue: goalKindRaw) ?? .maintain }
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
                goalPicker
                ringSection
                macrosSection
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
        // Pinned above the tab bar (not the last item in the scroll content) so it's always one tap
        // away without scrolling — matches LiveWorkoutView's floating bottom control bar convention.
        .safeAreaInset(edge: .bottom, spacing: 0) {
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
        .sheet(isPresented: $showGoalsSheet) {
            FoodGoalsSheet(kcal: $goalKcal, protein: $goalProtein, carbs: $goalCarbs, fat: $goalFat)
        }
    }

    // MARK: - Floating "Log meal" (pinned above the tab bar)

    private var logMealButton: some View {
        NoopButton("Log meal", systemImage: "plus", kind: .primary, fullWidth: true) {
            showLogSheet = true
        }
        .padding(.horizontal, NoopMetrics.screenHPadding)
        .padding(.top, NoopMetrics.space2)
        .padding(.bottom, NoopMetrics.space2)
        .background {
            NoopPanelSurface(cornerRadius: 0, elevated: true).ignoresSafeArea(edges: .bottom)
        }
    }

    // MARK: - Goal picker (drives the suggested calorie target)

    private var goalPicker: some View {
        VStack(alignment: .leading, spacing: 8) {
            Picker("Goal", selection: Binding(
                get: { goalKind },
                set: { newKind in
                    goalKindRaw = newKind.rawValue
                    goalKcal = CalorieTarget.targetKcal(bmr: bmr, recentDailyBurns: recentDailyBurns, goal: newKind)
                }
            )) {
                ForEach(CalorieGoalKind.allCases) { kind in Text(kind.label).tag(kind) }
            }
            .pickerStyle(.segmented)
            Text(recentDailyBurns.count >= CalorieTarget.minDaysForMeasuredTDEE
                 ? "Target based on your last \(recentDailyBurns.count) days' measured burn."
                 : "Target based on an estimate — measured burn kicks in after a few more days of data.")
                .font(StrandFont.footnote)
                .foregroundStyle(StrandPalette.textTertiary)
        }
    }

    // MARK: - Hero ring (calories eaten vs. goal)

    private var ringSection: some View {
        NoopCard {
            VStack(spacing: NoopMetrics.cardInnerSpacing) {
                ZStack {
                    LiquidVessel(value: heroFraction, tint: StrandPalette.metricAmber, animated: true)
                        .frame(width: 184, height: 184)
                    VStack(spacing: 2) {
                        CountUpText(value: totals.kcal,
                                    format: { String(Int($0.rounded())) },
                                    font: StrandFont.rounded(40, weight: .bold),
                                    color: StrandPalette.textPrimary)
                            .shadow(color: .black.opacity(0.5), radius: 6, y: 1)
                        Text("of \(Int(goalKcal)) kcal")
                            .font(StrandFont.subhead)
                            .foregroundStyle(StrandPalette.textSecondary)
                    }
                    .allowsHitTesting(false)
                }
                .accessibilityElement(children: .ignore)
                .accessibilityLabel("Calories today")
                .accessibilityValue("\(Int(totals.kcal.rounded())) of \(Int(goalKcal)) kcal")
                Button("Edit goals") { showGoalsSheet = true }
                    .font(StrandFont.footnote)
            }
            .frame(maxWidth: .infinity)
        }
    }

    // MARK: - Macro bars

    private var macrosSection: some View {
        NoopCard {
            VStack(alignment: .leading, spacing: NoopMetrics.gap) {
                PipBarRow(label: "Protein", value: totals.protein, range: 0...max(goalProtein, totals.protein, 1),
                         tint: StrandPalette.textPrimary, valueText: "\(Int(totals.protein.rounded()))",
                         unit: "of \(Int(goalProtein))g")
                PipBarRow(label: "Carbs", value: totals.carbs, range: 0...max(goalCarbs, totals.carbs, 1),
                         tint: StrandPalette.metricCyan, valueText: "\(Int(totals.carbs.rounded()))",
                         unit: "of \(Int(goalCarbs))g")
                PipBarRow(label: "Fat", value: totals.fat, range: 0...max(goalFat, totals.fat, 1),
                         tint: StrandPalette.effortColor, valueText: "\(Int(totals.fat.rounded()))",
                         unit: "of \(Int(goalFat))g")
            }
        }
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
        ForEach(FoodMealType.allCases) { type in
            let rows = entries.filter { $0.mealType == type.rawValue }
            if !rows.isEmpty {
                NoopCard {
                    VStack(alignment: .leading, spacing: NoopMetrics.gap) {
                        HStack(spacing: 6) {
                            Image(systemName: type.icon).foregroundStyle(StrandPalette.accent)
                            Text(type.label).strandOverline()
                        }
                        VStack(spacing: 0) {
                            ForEach(Array(rows.enumerated()), id: \.element.id) { idx, entry in
                                entryRow(entry)
                                if idx < rows.count - 1 { Divider().opacity(0.4) }
                            }
                        }
                    }
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

// MARK: - Goals editor

private struct FoodGoalsSheet: View {
    @Binding var kcal: Double
    @Binding var protein: Double
    @Binding var carbs: Double
    @Binding var fat: Double

    @Environment(\.dismiss) private var dismiss
    @State private var kcalText: String
    @State private var proteinText: String
    @State private var carbsText: String
    @State private var fatText: String

    init(kcal: Binding<Double>, protein: Binding<Double>, carbs: Binding<Double>, fat: Binding<Double>) {
        _kcal = kcal; _protein = protein; _carbs = carbs; _fat = fat
        _kcalText = State(initialValue: String(Int(kcal.wrappedValue)))
        _proteinText = State(initialValue: String(Int(protein.wrappedValue)))
        _carbsText = State(initialValue: String(Int(carbs.wrappedValue)))
        _fatText = State(initialValue: String(Int(fat.wrappedValue)))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: NoopMetrics.sectionGap) {
            Text("Daily goals")
                .font(StrandFont.title2)
                .foregroundStyle(StrandPalette.textPrimary)
            Text("Calories default to a suggestion based on your profile and goal — edit here to override it.")
                .font(StrandFont.footnote)
                .foregroundStyle(StrandPalette.textSecondary)
            goalField("Calories", text: $kcalText, unit: "kcal")
            goalField("Protein", text: $proteinText, unit: "g")
            goalField("Carbs", text: $carbsText, unit: "g")
            goalField("Fat", text: $fatText, unit: "g")
            HStack(spacing: NoopMetrics.gap) {
                NoopButton("Cancel", kind: .secondary, fullWidth: true) { dismiss() }
                NoopButton("Save", kind: .primary, fullWidth: true) {
                    kcal = Double(kcalText) ?? kcal
                    protein = Double(proteinText) ?? protein
                    carbs = Double(carbsText) ?? carbs
                    fat = Double(fatText) ?? fat
                    dismiss()
                }
            }
        }
        .padding(NoopMetrics.space5)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(StrandPalette.surfaceBase.ignoresSafeArea())
        #if os(iOS)
        .presentationDetents([.height(400)])
        .presentationDragIndicator(.visible)
        #endif
    }

    private func goalField(_ label: String, text: Binding<String>, unit: String) -> some View {
        HStack {
            Text(label).font(StrandFont.subhead).foregroundStyle(StrandPalette.textSecondary)
            Spacer()
            TextField("", text: text)
                .textFieldStyle(.plain)
                .font(StrandFont.bodyNumber)
                .foregroundStyle(StrandPalette.textPrimary)
                .numericKeyboard()
                .multilineTextAlignment(.trailing)
                .frame(width: 70)
            Text(unit).font(StrandFont.footnote).foregroundStyle(StrandPalette.textTertiary)
        }
    }
}
