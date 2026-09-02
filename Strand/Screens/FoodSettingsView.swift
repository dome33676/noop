import SwiftUI
import StrandDesign
import WhoopStore

// MARK: - Food goals settings
//
// Moved out of the Food tab (previously an "Edit goals" sheet, `FoodGoalsSheet`) into its own screen
// under More → App, so goal-editing lives alongside every other settings surface instead of a modal
// popping out of the tab. Reads/writes the SAME @AppStorage keys FoodView.swift reads for its
// read-only display — SwiftUI @AppStorage is shared storage, so the two stay in sync automatically.
struct FoodSettingsView: View {
    @EnvironmentObject var repo: Repository
    @EnvironmentObject var profile: ProfileStore

    @AppStorage("foodGoalKcal") private var goalKcal = 2000.0
    @AppStorage("foodGoalProteinG") private var goalProtein = 150.0
    @AppStorage("foodGoalCarbsG") private var goalCarbs = 250.0
    @AppStorage("foodGoalFatG") private var goalFat = 70.0
    @AppStorage("foodGoalKind") private var goalKindRaw = CalorieGoalKind.maintain.rawValue

    /// (BMR + active kcal) for each of the last few past days that had Apple Health active-kcal data —
    /// the measured-TDEE input for `CalorieTarget`. Empty until enough days accumulate.
    @State private var recentDailyBurns: [Double] = []

    private var goalKind: CalorieGoalKind { CalorieGoalKind(rawValue: goalKindRaw) ?? .maintain }
    private var bmr: Double {
        CalorieTarget.bmr(sex: profile.sex, weightKg: profile.weightKg, heightCm: profile.heightCm, age: profile.age)
    }

    var body: some View {
        ScreenScaffold(title: "Food Goals") {
            VStack(alignment: .leading, spacing: NoopMetrics.sectionGap) {
                Text("Calories default to a suggestion based on your profile and goal below. Override any value manually if you'd rather set your own.")
                    .font(StrandFont.footnote)
                    .foregroundStyle(StrandPalette.textSecondary)
                goalPicker
                overridesSection
            }
        }
        .task { await reloadEnergyData() }
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

    // MARK: - Manual overrides

    private var overridesSection: some View {
        NoopCard {
            VStack(alignment: .leading, spacing: NoopMetrics.gap) {
                Text("Daily goals").strandOverline()
                goalField("Calories", value: $goalKcal, unit: "kcal")
                goalField("Protein", value: $goalProtein, unit: "g")
                goalField("Carbs", value: $goalCarbs, unit: "g")
                goalField("Fat", value: $goalFat, unit: "g")
            }
        }
    }

    private func goalField(_ label: String, value: Binding<Double>, unit: String) -> some View {
        HStack {
            Text(label).font(StrandFont.subhead).foregroundStyle(StrandPalette.textSecondary)
            Spacer()
            TextField("", text: textBinding(for: value))
                .textFieldStyle(.plain)
                .font(StrandFont.bodyNumber)
                .foregroundStyle(StrandPalette.textPrimary)
                .numericKeyboard()
                .multilineTextAlignment(.trailing)
                .frame(width: 70)
            Text(unit).font(StrandFont.footnote).foregroundStyle(StrandPalette.textTertiary)
        }
    }

    /// Live String<->Double bridge so the field commits straight to the @AppStorage-backed binding on
    /// every keystroke — this is a persistent settings screen, not a modal with its own Save/Cancel, so
    /// there's no separate draft state to reconcile. An unparsable in-progress edit (e.g. an emptied
    /// field) leaves the underlying value untouched rather than snapping it to 0.
    private func textBinding(for value: Binding<Double>) -> Binding<String> {
        Binding(
            get: { String(Int(value.wrappedValue)) },
            set: { newText in if let parsed = Double(newText) { value.wrappedValue = parsed } }
        )
    }

    // MARK: - Data

    /// Builds the measured-TDEE input from Apple Health's daily aggregates — same logic as
    /// FoodView.reloadEnergyData(), duplicated here since this screen only needs the burns input, not
    /// the rest of that function's food-log energy-balance chart.
    private func reloadEnergyData() async {
        let appleDaily = await repo.appleDailyRows(days: 10)

        var activeByDay: [String: Double] = [:]
        for row in appleDaily where row.activeKcal != nil { activeByDay[row.day] = row.activeKcal }

        let todayKey = Repository.localDayKey(Date())
        let bmrValue = bmr
        let pastDaysWithData = activeByDay.keys.filter { $0 != todayKey }.sorted().suffix(7)
        recentDailyBurns = pastDaysWithData.compactMap { activeByDay[$0] }.map { bmrValue + $0 }
    }
}
