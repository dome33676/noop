import SwiftUI
import StrandDesign
import WhoopStore

// MARK: - Backfill ("nachtragen") a past training
//
// `StartTrainingSheet` → `ActiveTrainingView` is wrong for this: that flow creates a session with
// `endTs: nil` and opens a live rest-timer per set (durationS/restBeforeS measured in real time),
// which is meaningless for a workout that already happened. This is a separate, static form instead —
// pick a past date, list exercises with already-known reps/weight/warmup/effort typed in directly, then
// persist with ONE `saveStrengthSession` call followed by N `logStrengthSet` calls (the same two-call
// shape `ActiveTrainingController` uses; there is no batch API). Each set's `completedAt` is back-dated
// into the chosen day, strictly increasing in entry order, so the session renders "completed" (not
// "Active") and PR/progression logic — which sorts by `completedAt` — sees the sets in the right order.
//
// Field idioms are reused verbatim rather than reinvented: `numberInput`/effort scale/warm-up toggle
// from `LogSetSheet`, the exercise-card layout from `TemplateEditorView`, exercise picking from the
// existing (non-private) `ExercisePickerSheet`.

struct BackfillTrainingSheet: View {
    let onSaved: () -> Void
    @EnvironmentObject private var repo: Repository
    @Environment(\.dismiss) private var dismiss
    @AppStorage(UnitPrefs.systemKey) private var unitSystemRaw = UnitSystem.metric.rawValue
    @AppStorage("trainingEffortScale") private var effortScaleRaw = "rir"   // same key LogSetSheet uses

    @State private var date = Date()
    @State private var templates: [StrengthTemplateRow] = []
    @State private var exercises: [ExerciseEntry] = []
    @State private var showAddExercise = false

    private var unitSystem: UnitSystem { UnitSystem(rawValue: unitSystemRaw) ?? .metric }
    private var weightUnit: String { unitSystem == .imperial ? "lb" : "kg" }

    /// One exercise actually performed, with the sets as typed in (not targets — this is a record of
    /// what happened, unlike `TemplateExercisePlan`'s planned reps/weight).
    private struct ExerciseEntry: Identifiable {
        let id = UUID()
        var name: String
        var sets: [SetEntry] = []
    }

    /// One performed set. `effortText` reads against the shared `effortScaleRaw` toggle, exactly like
    /// `LogSetSheet` — there is one scale preference, not one per set.
    private struct SetEntry: Identifiable {
        let id = UUID()
        var repsText = ""
        var weightText = ""
        var isWarmup = false
        var effortText = ""
    }

    var body: some View {
        ScreenScaffold(title: "Backfill Training") {
            VStack(alignment: .leading, spacing: NoopMetrics.sectionGap) {
                field("When") {
                    DatePicker("", selection: $date, in: ...Date(), displayedComponents: [.date, .hourAndMinute])
                        .labelsHidden()
                }
                // Only offered while the list is still empty — picking a template after exercises have
                // already been added would silently clobber whatever work is in progress.
                if !templates.isEmpty && exercises.isEmpty {
                    Menu {
                        ForEach(templates) { template in
                            Button(template.name) {
                                exercises = template.plan.map { ExerciseEntry(name: $0.exerciseName) }
                            }
                        }
                    } label: {
                        Label("Or start from a template", systemImage: "square.stack")
                            .font(StrandFont.subhead)
                            .foregroundStyle(StrandPalette.accent)
                    }
                }
                ForEach($exercises) { $exercise in
                    exerciseCard($exercise)
                }
                NoopButton("Add Exercise", systemImage: "plus", kind: .secondary, fullWidth: true) {
                    showAddExercise = true
                }
                NoopButton("Save", systemImage: "checkmark", kind: .primary, fullWidth: true) {
                    save()
                }
                .disabled(exercises.isEmpty || exercises.allSatisfy { $0.sets.isEmpty })
            }
        }
        .task { templates = await repo.strengthTemplates() }
        .sheet(isPresented: $showAddExercise) {
            ExercisePickerSheet { name in exercises.append(ExerciseEntry(name: name)) }
        }
    }

    private func exerciseCard(_ exercise: Binding<ExerciseEntry>) -> some View {
        NoopCard {
            VStack(alignment: .leading, spacing: NoopMetrics.gap) {
                HStack {
                    Text(exercise.wrappedValue.name).strandOverline()
                    Spacer()
                    Button(role: .destructive) {
                        exercises.removeAll { $0.id == exercise.wrappedValue.id }
                    } label: {
                        Image(systemName: "trash")
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(StrandPalette.textTertiary)
                    }
                    .buttonStyle(.plain)
                }
                ForEach(exercise.wrappedValue.sets.indices, id: \.self) { setIdx in
                    setRow(exercise, setIndex: setIdx)
                    if setIdx < exercise.wrappedValue.sets.count - 1 { Divider().opacity(0.3) }
                }
                Button {
                    // Carry forward the last set's reps/weight (the common "same weight, next set"
                    // case), same as TemplateEditorView's "Add Set" — but reset warm-up/effort, since
                    // those describe THIS set, not a target that repeats.
                    let last = exercise.wrappedValue.sets.last
                    var next = SetEntry()
                    next.repsText = last?.repsText ?? ""
                    next.weightText = last?.weightText ?? ""
                    exercise.wrappedValue.sets.append(next)
                } label: {
                    Label("Add Set", systemImage: "plus")
                        .font(StrandFont.footnote.weight(.semibold))
                        .foregroundStyle(StrandPalette.accent)
                }
                .buttonStyle(.plain)
            }
        }
    }

    private func setRow(_ exercise: Binding<ExerciseEntry>, setIndex: Int) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Set \(setIndex + 1)")
                    .font(StrandFont.footnote)
                    .foregroundStyle(StrandPalette.textTertiary)
                Spacer()
                Button {
                    exercise.wrappedValue.sets.remove(at: setIndex)
                } label: {
                    Image(systemName: "minus.circle.fill")
                        .font(.system(size: 15))
                        .foregroundStyle(StrandPalette.textTertiary)
                }
                .buttonStyle(.plain)
            }
            HStack(spacing: 10) {
                numberInput("optional", text: exercise.sets[setIndex].repsText, unit: "reps")
                numberInput("optional", text: exercise.sets[setIndex].weightText, unit: weightUnit)
            }
            HStack(spacing: 10) {
                SegmentedPillControl(["rir", "rpe"], selection: $effortScaleRaw) { $0.uppercased() }
                numberInput("optional", text: exercise.sets[setIndex].effortText, unit: effortScaleRaw.uppercased())
            }
            Toggle("Warm-up set", isOn: exercise.sets[setIndex].isWarmup)
                .tint(StrandPalette.accent)
        }
        .padding(.vertical, 6)
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

    private func field<Content: View>(_ label: String, @ViewBuilder _ content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(label).strandOverline()
            content()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// Parsed weight in stored KILOGRAMS — verbatim LogSetSheet's conversion.
    private func weightKg(_ text: String) -> Double? {
        let t = text.trimmingCharacters(in: .whitespaces)
        guard !t.isEmpty, let v = Double(t), v >= 0 else { return nil }
        return unitSystem == .imperial ? v / UnitFormatter.poundsPerKilogram : v
    }

    private func effort(_ text: String) -> Double? {
        let t = text.trimmingCharacters(in: .whitespaces)
        guard !t.isEmpty, let v = Double(t), v >= 0 else { return nil }
        return v
    }

    private func save() {
        let startTs = Int(date.timeIntervalSince1970)
        let totalSets = exercises.reduce(0) { $0 + $1.sets.count }   // >=1 — Save is disabled otherwise
        let session = StrengthSessionRow(
            id: UUID().uuidString, deviceId: WhoopStore.strengthLogSourceId,
            name: "Training — " + Self.dateFmt.string(from: date),
            // Non-nil endTs is what keeps this off the "Active" badge; the +3s/set is nominal spacing,
            // not a real duration — nothing here measures how long the training actually took.
            startTs: startTs, endTs: startTs + totalSets * 3,
            notes: nil
        )
        Task {
            await repo.saveStrengthSession(session)
            var completedAt = startTs
            for exercise in exercises {
                for (idx, set) in exercise.sets.enumerated() {
                    // Strictly increasing across the WHOLE session, in entry order — this is the field
                    // ExerciseProgressionView/PR logic sorts by, so it has to reflect the order the sets
                    // were actually typed in, not just be "some timestamp in the right day".
                    completedAt += 3
                    let effortValue = effort(set.effortText)
                    let row = StrengthSetRow(
                        id: UUID().uuidString, deviceId: WhoopStore.strengthLogSourceId, sessionId: session.id,
                        exerciseName: exercise.name, setIndex: idx,
                        reps: Int(set.repsText.trimmingCharacters(in: .whitespaces)),
                        weightKg: weightKg(set.weightText),
                        setDurationS: nil, restBeforeS: nil,   // no timer data — the whole point of this flow
                        isWarmup: set.isWarmup,
                        effortValue: effortValue, effortScale: effortValue == nil ? nil : effortScaleRaw,
                        completedAt: completedAt
                    )
                    await repo.logStrengthSet(row)
                }
            }
            onSaved()
            dismiss()
        }
    }

    private static let dateFmt: DateFormatter = {
        let f = DateFormatter(); f.dateStyle = .medium; f.timeStyle = .short; return f
    }()
}
