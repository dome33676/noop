import SwiftUI
import StrandDesign
import WhoopStore

// MARK: - Template editor
//
// Create or edit a reusable training plan: a name, and an ordered list of exercises, each with an
// ordered list of per-set targets (reps + weight) — a pyramid like 12/10/8 reps is one exercise with
// three differently-targeted sets, not three exercises. Mirrors `ManualWorkoutSheet`'s field()/footer
// idiom; exercise picking reuses `ExercisePickerSheet` from the active-training screen.

struct TemplateEditorView: View {
    let editing: StrengthTemplateRow?
    let onSave: (StrengthTemplateRow) -> Void

    @EnvironmentObject private var repo: Repository
    @Environment(\.dismiss) private var dismiss
    @State private var name: String
    @State private var plan: [TemplateExercisePlan]
    @State private var restTargetSeconds: Int
    @State private var showAddExercise = false
    /// Per-exercise "last time" sets (most recent past session, any template), keyed by exercise
    /// name — loaded for every exercise already in `plan` on appear, and for a freshly-added one, so
    /// the user never has to recall their own last weights/reps when building a template.
    @State private var lastSets: [String: [StrengthSetRow]] = [:]

    init(editing: StrengthTemplateRow? = nil, onSave: @escaping (StrengthTemplateRow) -> Void) {
        self.editing = editing
        self.onSave = onSave
        _name = State(initialValue: editing?.name ?? "")
        _plan = State(initialValue: editing?.plan ?? [])
        _restTargetSeconds = State(initialValue: editing?.restTargetSeconds ?? ActiveTrainingController.defaultRestTargetSeconds)
    }

    var body: some View {
        ScreenScaffold(title: "Template") {
            VStack(alignment: .leading, spacing: NoopMetrics.sectionGap) {
                field("Name") {
                    TextField("e.g. Push Day", text: $name)
                        .textFieldStyle(.plain)
                        .font(StrandFont.body)
                        .foregroundStyle(StrandPalette.textPrimary)
                        .padding(.horizontal, 12).padding(.vertical, 9)
                        .background(StrandPalette.surfaceInset, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                }
                field("Rest timer") {
                    Picker("", selection: $restTargetSeconds) {
                        ForEach([30, 45, 60, 90, 120, 150, 180, 240], id: \.self) { seconds in
                            Text(ActiveWorkoutClock.clock(seconds)).tag(seconds)
                        }
                    }
                    .pickerStyle(.menu)
                    .labelsHidden()
                }
                ForEach($plan, id: \.exerciseName) { $exercisePlan in
                    exerciseCard($exercisePlan)
                }
                NoopButton("Add Exercise", systemImage: "plus", kind: .secondary, fullWidth: true) {
                    showAddExercise = true
                }
                NoopButton(editing == nil ? "Save Template" : "Save Changes", systemImage: "checkmark",
                          kind: .primary, fullWidth: true) {
                    save()
                }
                .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty || plan.isEmpty)
            }
        }
        .task {
            for exerciseName in plan.map(\.exerciseName) { await loadLastSets(for: exerciseName) }
        }
        .sheet(isPresented: $showAddExercise) {
            ExercisePickerSheet { name in
                guard !plan.contains(where: { $0.exerciseName == name }) else { return }
                Task {
                    await loadLastSets(for: name)
                    let last = lastSets[name] ?? []
                    let seededSets = last.isEmpty
                        ? [TemplateSetPlan(targetReps: nil, targetWeightKg: nil)]
                        : last.map { TemplateSetPlan(targetReps: $0.reps, targetWeightKg: $0.weightKg) }
                    plan.append(TemplateExercisePlan(exerciseName: name, sets: seededSets))
                }
            }
        }
    }

    /// Fetches the exercise's most recent past session (any template, any session) and caches it in
    /// `lastSets`, so both the "Last time" caption and a freshly-added exercise's prefilled sets can
    /// read it. Exercise identity is a plain name string (same space `Repository.strengthSets`,
    /// `CustomExerciseStore`, and `ProgressionCalculator` already use), so this works identically
    /// whether the exercise was last logged from a different template or none at all.
    private func loadLastSets(for exerciseName: String) async {
        let history = await repo.strengthSets(exerciseName: exerciseName)
        lastSets[exerciseName] = ProgressionCalculator.lastSessionSets(from: history)
    }

    private func exerciseCard(_ exercisePlan: Binding<TemplateExercisePlan>) -> some View {
        NoopCard {
            VStack(alignment: .leading, spacing: NoopMetrics.gap) {
                HStack {
                    Text(exercisePlan.wrappedValue.exerciseName).strandOverline()
                    Spacer()
                    Button(role: .destructive) {
                        plan.removeAll { $0.exerciseName == exercisePlan.wrappedValue.exerciseName }
                    } label: {
                        Image(systemName: "trash")
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(StrandPalette.textTertiary)
                    }
                    .buttonStyle(.plain)
                }
                if let hint = lastTimeHint(for: exercisePlan.wrappedValue.exerciseName) {
                    Text(hint)
                        .font(StrandFont.caption)
                        .foregroundStyle(StrandPalette.textTertiary)
                }
                ForEach(exercisePlan.wrappedValue.sets.indices, id: \.self) { setIdx in
                    setRow(exercisePlan, setIndex: setIdx)
                }
                Button {
                    let last = exercisePlan.wrappedValue.sets.last
                    exercisePlan.wrappedValue.sets.append(
                        TemplateSetPlan(targetReps: last?.targetReps, targetWeightKg: last?.targetWeightKg))
                } label: {
                    Label("Add Set", systemImage: "plus")
                        .font(StrandFont.footnote.weight(.semibold))
                        .foregroundStyle(StrandPalette.accent)
                }
                .buttonStyle(.plain)
            }
        }
    }

    /// "Last time: 10 reps @ 60 kg, 8 reps @ 60 kg" — the exercise's most recent logged session,
    /// set by set, so the fields above are never a total guess even after the user edits them away
    /// from the prefilled values. nil while history hasn't loaded yet, or there is none.
    private func lastTimeHint(for exerciseName: String) -> String? {
        guard let sets = lastSets[exerciseName], !sets.isEmpty else { return nil }
        let parts = sets.map { set -> String in
            let reps = set.reps.map { "\($0)" } ?? "?"
            guard let weight = set.weightKg else { return "\(reps) reps" }
            return "\(reps) reps @ \(String(format: "%.1f", weight)) kg"
        }
        return "Last time: \(parts.joined(separator: ", "))"
    }

    private func setRow(_ exercisePlan: Binding<TemplateExercisePlan>, setIndex: Int) -> some View {
        HStack(spacing: 10) {
            Text("Set \(setIndex + 1)")
                .font(StrandFont.footnote)
                .foregroundStyle(StrandPalette.textTertiary)
                .frame(width: 44, alignment: .leading)
            numberField("reps", value: exercisePlan.sets[setIndex].targetReps)
            numberField("kg", value: exercisePlan.sets[setIndex].targetWeightKg)
            Button {
                exercisePlan.wrappedValue.sets.remove(at: setIndex)
            } label: {
                Image(systemName: "minus.circle.fill")
                    .font(.system(size: 15))
                    .foregroundStyle(StrandPalette.textTertiary)
            }
            .buttonStyle(.plain)
        }
    }

    /// A small inline reps/weight field. Generic over the stored numeric type so one helper serves
    /// both the `Int?` reps field and the `Double?` weight field.
    private func numberField<Value: LosslessStringConvertible>(_ unit: String, value: Binding<Value?>) -> some View {
        HStack(spacing: 4) {
            TextField("—", text: Binding(
                get: { value.wrappedValue.map { String($0) } ?? "" },
                // German-locale comma decimal, mirrors JournalLogCard's NumericLogField.
                set: { value.wrappedValue = $0.isEmpty ? nil : Value($0.trimmingCharacters(in: .whitespaces).replacingOccurrences(of: ",", with: ".")) }
            ))
            .textFieldStyle(.plain)
            .font(StrandFont.bodyNumber)
            .foregroundStyle(StrandPalette.textPrimary)
            .numericKeyboard()
            Text(unit).font(StrandFont.footnote).foregroundStyle(StrandPalette.textTertiary)
        }
        .padding(.horizontal, 10).padding(.vertical, 6)
        .frame(maxWidth: .infinity)
        .background(StrandPalette.surfaceInset, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
    }

    private func field<Content: View>(_ label: String, @ViewBuilder _ content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(label).strandOverline()
            content()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func save() {
        let now = Int(Date().timeIntervalSince1970)
        let template = StrengthTemplateRow(
            id: editing?.id ?? UUID().uuidString,
            deviceId: WhoopStore.strengthLogSourceId,
            name: name.trimmingCharacters(in: .whitespaces),
            planJSON: StrengthTemplateRow.encode(plan),
            createdAt: editing?.createdAt ?? now,
            updatedAt: now,
            restTargetSeconds: restTargetSeconds
        )
        onSave(template)
        dismiss()
    }
}
