import SwiftUI
import StrandDesign

// MARK: - Add a manual weight entry
//
// Weight (the Health-tile detail, "apple-health" source) had no way to log a value by hand. This is
// that one affordance: pick a day (defaults to today, backdatable), type a weight in the user's unit
// system, Save. Mirrors `BackfillTrainingSheet`'s date-picker + field idioms and `LogSetSheet`'s exact
// comma-decimal weight parse. The write itself goes through `Repository.logManualWeight`
// (`ManualWeightStore`) — a last-write-wins upsert under its own source id, so it can never collide
// with an Apple Health import.

struct AddWeightSheet: View {
    let onSaved: () -> Void
    @EnvironmentObject private var repo: Repository
    @Environment(\.dismiss) private var dismiss
    @AppStorage(UnitPrefs.systemKey) private var unitSystemRaw = UnitSystem.metric.rawValue

    @State private var date = Date()
    @State private var weightText = ""

    private var unitSystem: UnitSystem { UnitSystem(rawValue: unitSystemRaw) ?? .metric }
    private var weightUnit: String { unitSystem == .imperial ? "lb" : "kg" }

    var body: some View {
        ScreenScaffold(title: "Add Weight") {
            VStack(alignment: .leading, spacing: NoopMetrics.sectionGap) {
                field("When") {
                    // Day only — weight's stored under one point per calendar day, no time component.
                    DatePicker("", selection: $date, in: ...Date(), displayedComponents: [.date])
                        .labelsHidden()
                }
                field("Weight") {
                    numberInput("required", text: $weightText, unit: weightUnit)
                }
                NoopButton("Save", systemImage: "checkmark", kind: .primary, fullWidth: true) {
                    save()
                }
                .disabled(weightKg == nil)
            }
        }
    }

    private func field<Content: View>(_ label: String, @ViewBuilder _ content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(label).strandOverline()
            content()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func numberInput(_ placeholder: String, text: Binding<String>, unit: String) -> some View {
        HStack(spacing: 6) {
            TextField(placeholder, text: text)
                .textFieldStyle(.plain)
                .font(StrandFont.bodyNumber)
                .foregroundStyle(StrandPalette.textPrimary)
                .numericKeyboard()
            Text(unit).font(StrandFont.footnote).foregroundStyle(StrandPalette.textTertiary)
        }
        .padding(.horizontal, 12).padding(.vertical, 9)
        .frame(maxWidth: .infinity)
        .background(StrandPalette.surfaceInset, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(StrandPalette.hairline, lineWidth: 1))
    }

    /// Parsed weight in stored KILOGRAMS — verbatim BackfillTrainingSheet/LogSetSheet's conversion.
    /// `v > 0` (not `>= 0`, unlike those sheets' optional set-weight): here weight is the one required
    /// field, so a blank/zero entry must not read as "valid".
    private var weightKg: Double? {
        // German-locale comma decimal, mirrors JournalLogCard's NumericLogField.
        let t = weightText.trimmingCharacters(in: .whitespaces).replacingOccurrences(of: ",", with: ".")
        guard !t.isEmpty, let v = Double(t), v > 0 else { return nil }
        return unitSystem == .imperial ? v / UnitFormatter.poundsPerKilogram : v
    }

    private func save() {
        guard let kg = weightKg else { return }
        let dayKey = Repository.localDayKey(date)
        Task {
            await repo.logManualWeight(kg: kg, day: dayKey)
            onSaved()
            dismiss()
        }
    }
}
