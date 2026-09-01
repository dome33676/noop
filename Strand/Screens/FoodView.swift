import SwiftUI
import StrandDesign
import WhoopStore

// MARK: - Food tab
//
// A day-diary over the food library: totals vs goals, meals grouped by type, log/edit/delete. Built
// from the locked Noop component system (NoopCard / StatTile / DayNavBar), matching Workouts rather
// than the "liquid" tabs — Food has no hero gauge, just numbers and a list, so the plainer surface is
// the honest fit. Entries are resolved against the food library client-side (loaded once per reload)
// so the totals shown always match the rows shown beneath them, with no second read that could disagree.

struct FoodView: View {
    @EnvironmentObject var repo: Repository

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

    private var today: Date { Date() }
    private var day: String {
        Repository.localDayKey(Calendar.current.date(byAdding: .day, value: -dayOffset, to: today) ?? today)
    }

    var body: some View {
        ScreenScaffold(title: "Food", subtitle: "Your meals, on this device only.",
                       onRefresh: { await reload() }) {
            VStack(alignment: .leading, spacing: NoopMetrics.sectionGap) {
                DayNavBar(selectedOffset: dayOffset, today: today) { newOffset in
                    dayOffset = newOffset
                    Task { await reload() }
                }
                totalsSection
                mealsSection
                NoopButton("Log meal", systemImage: "plus", kind: .primary, fullWidth: true) {
                    showLogSheet = true
                }
            }
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

    // MARK: - Totals vs goals

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

    private var totalsSection: some View {
        VStack(alignment: .leading, spacing: NoopMetrics.gap) {
            HStack {
                Text("Today's totals").strandOverline()
                Spacer()
                Button("Edit goals") { showGoalsSheet = true }
                    .font(StrandFont.footnote)
            }
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 150), spacing: NoopMetrics.gap)],
                     alignment: .leading, spacing: NoopMetrics.gap) {
                StatTile(label: "Calories", value: "\(Int(totals.kcal.rounded()))",
                         caption: "of \(Int(goalKcal)) kcal", accent: StrandPalette.metricAmber)
                StatTile(label: "Protein", value: "\(Int(totals.protein.rounded()))g",
                         caption: "of \(Int(goalProtein))g", accent: StrandPalette.textPrimary)
                StatTile(label: "Carbs", value: "\(Int(totals.carbs.rounded()))g",
                         caption: "of \(Int(goalCarbs))g", accent: StrandPalette.metricCyan)
                StatTile(label: "Fat", value: "\(Int(totals.fat.rounded()))g",
                         caption: "of \(Int(goalFat))g", accent: StrandPalette.effortColor)
            }
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

    // MARK: - Data

    private func reload() async {
        let day = self.day
        async let entriesTask = repo.mealEntries(day: day)
        async let libraryTask = repo.foodItems()
        entries = await entriesTask
        let library = await libraryTask
        foodsById = Dictionary(uniqueKeysWithValues: library.map { ($0.id, $0) })
        loaded = true
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
        .presentationDetents([.height(360)])
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
