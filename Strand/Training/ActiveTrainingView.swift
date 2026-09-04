import SwiftUI
import StrandDesign
import WhoopStore

// MARK: - Active training screen
//
// One running session: elapsed-time header (TimelineView, matching LiveWorkoutView's convention),
// an exercise chip row, the active exercise's set/rest timer with a big Start/End Set control, and
// the sets already logged. While this screen is visible it hijacks the strap's physical double-tap
// (via `AppModel.doubleTapInterceptor`) to start/end a set instead of the user's configured
// double-tap action — cleared the moment the screen goes away, so every other screen is unaffected.

struct ActiveTrainingView: View {
    @EnvironmentObject private var repo: Repository
    @EnvironmentObject private var model: AppModel
    @StateObject private var controller: ActiveTrainingController
    @Environment(\.dismiss) private var dismiss

    @State private var showAddExercise = false
    @State private var showEndConfirm = false

    /// `repo`/`model` are read from the caller's own `@EnvironmentObject`s and passed through
    /// explicitly — environment values aren't available inside a custom `init`, and `@StateObject`
    /// needs the controller constructed with them up front. `template` is nil for a blank session.
    init(session: StrengthSessionRow, repo: Repository, model: AppModel, template: StrengthTemplateRow? = nil) {
        _controller = StateObject(wrappedValue: ActiveTrainingController(
            session: session, repo: repo, model: model, template: template))
    }

    var body: some View {
        // This screen is presented full-screen (not pushed), so it needs its own NavigationStack for
        // the in-content "view progression" NavigationLink to render enabled rather than orphaned.
        NavigationStack {
            content
        }
    }

    private var content: some View {
        ScreenScaffold(title: LocalizedStringKey(controller.session.name), subtitle: "Training in progress") {
            VStack(alignment: .leading, spacing: NoopMetrics.sectionGap) {
                elapsedHeader
                exerciseChips
                if let exercise = controller.selectedExercise {
                    activeExerciseCard(exercise)
                } else {
                    NoopCard {
                        Text("Add an exercise to start logging sets.")
                            .font(StrandFont.subhead)
                            .foregroundStyle(StrandPalette.textSecondary)
                    }
                }
                NoopButton("End Training", systemImage: "flag.checkered", kind: .secondary, fullWidth: true) {
                    showEndConfirm = true
                }
            }
        }
        .task { await controller.load() }
        .onAppear { model.doubleTapInterceptor = { [weak controller] in controller?.toggleSet() ?? false } }
        .onDisappear { model.doubleTapInterceptor = nil }
        .sheet(isPresented: $showAddExercise) {
            ExercisePickerSheet { name in controller.addExercise(name) }
        }
        .sheet(item: $controller.pendingSet) { pending in
            LogSetSheet(pending: pending) { reps, weightKg, isWarmup, effortValue, effortScale in
                Task {
                    await controller.confirmPendingSet(
                        pending, reps: reps, weightKg: weightKg, isWarmup: isWarmup,
                        effortValue: effortValue, effortScale: effortScale)
                }
            } onCancel: {
                controller.discardPendingSet()
            }
        }
        .confirmationDialog("End this training?", isPresented: $showEndConfirm, titleVisibility: .visible) {
            Button("Save & End") {
                Task { await controller.endTraining(); dismiss() }
            }
            Button("Discard Training", role: .destructive) {
                Task { await controller.discardTraining(); dismiss() }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Save keeps every logged set and updates the template. Discard deletes this training entirely.")
        }
    }

    // MARK: - Header clock

    private var elapsedHeader: some View {
        TimelineView(.periodic(from: .now, by: 1)) { context in
            let elapsed = ActiveWorkoutClock.activeElapsed(
                start: Date(timeIntervalSince1970: TimeInterval(controller.session.startTs)),
                pausedAt: nil, pausedDuration: 0, now: context.date
            )
            Text(ActiveWorkoutClock.clock(Int(elapsed)))
                .font(StrandFont.rounded(40, weight: .bold))
                .foregroundStyle(StrandPalette.textPrimary)
                .monospacedDigit()
                .frame(maxWidth: .infinity, alignment: .center)
                .accessibilityLabel("Training duration")
        }
    }

    // MARK: - Exercise chips

    private var exerciseChips: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(controller.exerciseNames, id: \.self) { name in
                    Button { controller.selectedExercise = name } label: {
                        HStack(spacing: 4) {
                            if controller.isComplete(name) {
                                Image(systemName: "checkmark.circle.fill")
                                    .font(.system(size: 12))
                                    .foregroundStyle(StrandPalette.statusPositive)
                            }
                            Text(name)
                                .font(StrandFont.subhead.weight(name == controller.selectedExercise ? .bold : .regular))
                                .foregroundStyle(name == controller.selectedExercise
                                                 ? StrandPalette.textPrimary : StrandPalette.textSecondary)
                        }
                        .padding(.horizontal, 14).padding(.vertical, 8)
                        .background(
                            name == controller.selectedExercise ? StrandPalette.accent.opacity(0.18)
                                                                : StrandPalette.surfaceInset,
                            in: Capsule()
                        )
                    }
                    .buttonStyle(.plain)
                }
                Button { showAddExercise = true } label: {
                    Image(systemName: "plus")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(StrandPalette.accent)
                        .frame(width: 36, height: 36)
                        .background(StrandPalette.surfaceInset, in: Circle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Add exercise")
            }
        }
    }

    // MARK: - Active exercise card

    private func activeExerciseCard(_ exercise: String) -> some View {
        NoopCard {
            VStack(alignment: .leading, spacing: NoopMetrics.gap) {
                HStack {
                    Text(exercise).strandOverline()
                    if controller.isComplete(exercise) {
                        Label("Completed", systemImage: "checkmark.circle.fill")
                            .font(StrandFont.footnote.weight(.semibold))
                            .foregroundStyle(StrandPalette.statusPositive)
                    }
                    Spacer()
                    NavigationLink {
                        ExerciseProgressionView(exerciseName: exercise)
                    } label: {
                        Image(systemName: "chart.line.uptrend.xyaxis")
                            .foregroundStyle(StrandPalette.accent)
                    }
                    .accessibilityLabel("View progression for \(exercise)")
                }
                if controller.lastLoggedWasPR {
                    Label("New PR!", systemImage: "trophy.fill")
                        .font(StrandFont.footnote.weight(.semibold))
                        .foregroundStyle(StrandPalette.statusPositive)
                }
                if let hint = controller.targetHint(for: exercise) {
                    Text(hint)
                        .font(StrandFont.footnote.weight(.medium))
                        .foregroundStyle(StrandPalette.accent)
                } else if controller.isComplete(exercise) {
                    Text("All planned sets logged. Starting another set adds an extra one.")
                        .font(StrandFont.footnote)
                        .foregroundStyle(StrandPalette.textTertiary)
                }
                setTimer(exercise)
                NoopButton(
                    controller.setStartedAt != nil ? "End Set" : "Start Set",
                    systemImage: controller.setStartedAt != nil ? "stop.fill" : "play.fill",
                    kind: controller.setStartedAt != nil ? .secondary : .primary,
                    fullWidth: true
                ) {
                    controller.toggleSet()
                }
                Text("Double-tap your strap to do the same — your usual double-tap action is paused while this screen is open.")
                    .font(StrandFont.footnote)
                    .foregroundStyle(StrandPalette.textTertiary)
                let logged = controller.sets(for: exercise)
                if !logged.isEmpty {
                    Divider().opacity(0.4)
                    VStack(spacing: 0) {
                        ForEach(Array(logged.enumerated()), id: \.element.id) { idx, set in
                            setRow(set, index: idx, logged: logged)
                            if idx < logged.count - 1 { Divider().opacity(0.3) }
                        }
                    }
                }
            }
        }
    }

    private func setTimer(_ exercise: String) -> some View {
        TimelineView(.periodic(from: .now, by: 1)) { context in
            let _: Void = controller.checkRestBuzz(now: context.date)
            let (label, seconds): (String, Int) = {
                if let startedAt = controller.setStartedAt {
                    return ("Set time", Int(context.date.timeIntervalSince(startedAt)))
                } else if let lastEnd = controller.lastAnySetEndedAt {
                    return ("Rest", Int(context.date.timeIntervalSince(lastEnd)))
                } else {
                    return ("Ready", 0)
                }
            }()
            HStack {
                Text(label).font(StrandFont.footnote).foregroundStyle(StrandPalette.textTertiary)
                Spacer()
                Text(ActiveWorkoutClock.clock(seconds))
                    .font(StrandFont.rounded(28, weight: .semibold))
                    .foregroundStyle(controller.setStartedAt != nil ? StrandPalette.accent : StrandPalette.textPrimary)
                    .monospacedDigit()
            }
        }
    }

    /// `logged` is every set for this exercise already shown in THIS list (current session only, in
    /// order) — the trophy icon here checks "best set so far in today's session", a lighter-weight
    /// visual than the authoritative full-history PR check (`controller.lastLoggedWasPR`, set once
    /// live when a set is confirmed).
    private func setRow(_ set: StrengthSetRow, index: Int, logged: [StrengthSetRow]) -> some View {
        HStack {
            Text("Set \(index + 1)")
                .font(StrandFont.footnote)
                .foregroundStyle(StrandPalette.textTertiary)
            if set.isWarmup {
                Text("Warm-up")
                    .font(StrandFont.footnote)
                    .foregroundStyle(StrandPalette.textTertiary)
            }
            if PRDetector.isPR(set, among: Array(logged[..<index])) {
                Image(systemName: "trophy.fill")
                    .font(.system(size: 11))
                    .foregroundStyle(StrandPalette.statusPositive)
            }
            Spacer()
            if let reps = set.reps, let weight = set.weightKg {
                Text("\(reps) × \(String(format: "%.1f", weight)) kg")
                    .font(StrandFont.subhead)
                    .foregroundStyle(StrandPalette.textPrimary)
            } else if let reps = set.reps {
                Text("\(reps) reps")
                    .font(StrandFont.subhead)
                    .foregroundStyle(StrandPalette.textPrimary)
            }
            if let value = set.effortValue, let scale = set.effortScale {
                Text("· \(scale.uppercased()) \(String(format: "%.1f", value))")
                    .font(StrandFont.footnote)
                    .foregroundStyle(StrandPalette.textTertiary)
            }
            Button(role: .destructive) {
                Task { await controller.deleteSet(set) }
            } label: {
                Image(systemName: "trash")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(StrandPalette.textTertiary)
            }
            .buttonStyle(.plain)
        }
        .padding(.vertical, 4)
    }
}

// MARK: - Exercise picker (catalog + free text, mirrors LogMealSheet's food picker)
// Not private: also used by TemplateEditorView.

struct ExercisePickerSheet: View {
    let onPick: (String) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var query = ""

    private var results: [ExerciseCatalog.Exercise] { ExerciseCatalog.matching(query) }

    var body: some View {
        VStack(alignment: .leading, spacing: NoopMetrics.space5) {
            Text("Add Exercise")
                .font(StrandFont.title2)
                .foregroundStyle(StrandPalette.textPrimary)
            TextField("e.g. Bench Press", text: $query)
                .textFieldStyle(.plain)
                .font(StrandFont.body)
                .foregroundStyle(StrandPalette.textPrimary)
                .padding(.horizontal, 12).padding(.vertical, 9)
                .background(StrandPalette.surfaceInset, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            ScrollView {
                VStack(spacing: 0) {
                    ForEach(results) { exercise in
                        Button { onPick(exercise.name); dismiss() } label: {
                            Text(exercise.name)
                                .font(StrandFont.body)
                                .foregroundStyle(StrandPalette.textPrimary)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .contentShape(Rectangle())
                                .padding(.vertical, 10)
                        }
                        .buttonStyle(.plain)
                    }
                    if !query.trimmingCharacters(in: .whitespaces).isEmpty,
                       ExerciseCatalog.exercise(named: query) == nil {
                        Button { onPick(query); dismiss() } label: {
                            Label("Use \"\(query)\"", systemImage: "plus")
                                .font(StrandFont.body)
                                .foregroundStyle(StrandPalette.accent)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .contentShape(Rectangle())
                                .padding(.vertical, 10)
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
            NoopButton("Cancel", kind: .tertiary, fullWidth: true) { dismiss() }
        }
        .padding(NoopMetrics.space6)
        .frame(maxWidth: .infinity)
        .background(NoopChromeSurface())
        #if os(iOS)
        .noopSheetPresentation(largeFirst: false)
        #endif
    }
}
