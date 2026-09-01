import SwiftUI
import StrandDesign

// MARK: - Log-set confirmation sheet
//
// Shown right after a set ends (double-tap or manual Stop) to confirm reps/weight — the timer
// already measured duration and rest, so this is a two-field form, not a full re-entry. Weight/reps
// default to the previous set of the same exercise, so the common "same weight, next set" case is
// zero-typing (just tap Save). Mirrors `ManualWorkoutSheet`'s field()/footer idiom.

struct LogSetSheet: View {
    let pending: ActiveTrainingController.PendingSet
    let onConfirm: (_ reps: Int?, _ weightKg: Double?) -> Void
    let onCancel: () -> Void

    @Environment(\.dismiss) private var dismiss
    @AppStorage(UnitPrefs.systemKey) private var unitSystemRaw = UnitSystem.metric.rawValue
    private var unitSystem: UnitSystem { UnitSystem(rawValue: unitSystemRaw) ?? .metric }
    private var weightUnit: String { unitSystem == .imperial ? "lb" : "kg" }

    @State private var repsText: String
    @State private var weightText: String

    private enum NumberField: Hashable { case reps, weight }
    @FocusState private var focusedField: NumberField?

    init(pending: ActiveTrainingController.PendingSet,
         onConfirm: @escaping (_ reps: Int?, _ weightKg: Double?) -> Void,
         onCancel: @escaping () -> Void) {
        self.pending = pending
        self.onConfirm = onConfirm
        self.onCancel = onCancel
        _repsText = State(initialValue: pending.defaultReps.map(String.init) ?? "")
        let sys = UnitSystem(rawValue: UserDefaults.standard.string(forKey: UnitPrefs.systemKey) ?? "") ?? .metric
        _weightText = State(initialValue: pending.defaultWeightKg.map { Self.weightEntryString($0, system: sys) } ?? "")
    }

    private static func weightEntryString(_ kg: Double, system: UnitSystem) -> String {
        let value = system == .imperial ? UnitFormatter.kgToPounds(kg) : kg
        var s = String(format: "%.1f", value)
        while s.hasSuffix("0") { s.removeLast() }
        if s.hasSuffix(".") { s.removeLast() }
        return s
    }

    var body: some View {
        #if os(macOS)
        formContent
            .padding(NoopMetrics.space6)
            .frame(width: 380)
            .background(NoopChromeSurface())
            .keyboardDoneToolbar($focusedField)
        #else
        formContent
            .padding(NoopMetrics.space6)
            .frame(maxWidth: .infinity)
            .presentationDetents([.height(360)])
            .presentationDragIndicator(.visible)
            .background(NoopChromeSurface())
            .keyboardDoneToolbar($focusedField)
        #endif
    }

    private var formContent: some View {
        VStack(alignment: .leading, spacing: NoopMetrics.space5) {
            header
            HStack(spacing: 14) {
                statPill("Duration", ActiveWorkoutClock.clock(Int(pending.durationS.rounded())))
                if let rest = pending.restBeforeS {
                    statPill("Rest before", ActiveWorkoutClock.clock(Int(rest.rounded())))
                }
            }
            HStack(spacing: 14) {
                field("Reps") {
                    numberInput("optional", text: $repsText, unit: "reps", field: .reps)
                }
                field("Weight") {
                    numberInput("optional", text: $weightText, unit: weightUnit, field: .weight)
                }
            }
            footer
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(pending.exerciseName)
                .font(StrandFont.title2)
                .foregroundStyle(StrandPalette.textPrimary)
            Text("Set \(pending.setIndex + 1)")
                .font(StrandFont.subhead)
                .foregroundStyle(StrandPalette.textSecondary)
        }
    }

    private func statPill(_ label: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label).strandOverline()
            Text(value)
                .font(StrandFont.bodyNumber)
                .foregroundStyle(StrandPalette.textPrimary)
        }
        .padding(.horizontal, 12).padding(.vertical, 8)
        .background(StrandPalette.surfaceInset, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
    }

    private var footer: some View {
        HStack(spacing: NoopMetrics.space3) {
            NoopButton("Discard", kind: .tertiary) { onCancel(); dismiss() }
            Spacer()
            NoopButton("Save", systemImage: "checkmark", kind: .primary) { save() }
        }
    }

    private func field<Content: View>(_ label: String, @ViewBuilder _ content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(label).strandOverline()
            content()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func numberInput(_ placeholder: String, text: Binding<String>, unit: String, field: NumberField) -> some View {
        HStack(spacing: 6) {
            TextField(placeholder, text: text)
                .textFieldStyle(.plain)
                .font(StrandFont.bodyNumber)
                .foregroundStyle(StrandPalette.textPrimary)
                .numericKeyboard()
                .focused($focusedField, equals: field)
            Text(unit).font(StrandFont.footnote).foregroundStyle(StrandPalette.textTertiary)
        }
        .padding(.horizontal, 12).padding(.vertical, 9)
        .frame(maxWidth: .infinity)
        .background(StrandPalette.surfaceInset, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(StrandPalette.hairline, lineWidth: 1))
    }

    private var reps: Int? { Int(repsText.trimmingCharacters(in: .whitespaces)) }

    /// Parsed weight in stored KILOGRAMS — the user enters in their unit system.
    private var weightKg: Double? {
        let t = weightText.trimmingCharacters(in: .whitespaces)
        guard !t.isEmpty, let v = Double(t), v >= 0 else { return nil }
        return unitSystem == .imperial ? v / UnitFormatter.poundsPerKilogram : v
    }

    private func save() {
        onConfirm(reps, weightKg)
        dismiss()
    }
}
