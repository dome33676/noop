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

    @Environment(\.dismiss) private var dismiss
    @State private var name: String
    @State private var plan: [TemplateExercisePlan]
    @State private var showAddExercise = false

    init(editing: StrengthTemplateRow? = nil, onSave: @escaping (StrengthTemplateRow) -> Void) {
        self.editing = editing
        self.onSave = onSave
        _name = State(initialValue: editing?.name ?? "")
        _plan = State(initialValue: editing?.plan ?? [])
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
        .sheet(isPresented: $showAddExercise) {
            ExercisePickerSheet { name in
                guard !plan.contains(where: { $0.exerciseName == name }) else { return }
                plan.append(TemplateExercisePlan(exerciseName: name, sets: [TemplateSetPlan(targetReps: nil, targetWeightKg: nil)]))
            }
        }
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
                set: { value.wrappedValue = $0.isEmpty ? nil : Value($0.trimmingCharacters(in: .whitespaces)) }
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
            updatedAt: now
        )
        onSave(template)
        dismiss()
    }
}
