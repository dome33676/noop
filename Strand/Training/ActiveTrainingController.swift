import Foundation
import WhoopStore

/// Owns the mutable state of one active training session — a reference type (not `@State` on the
/// screen) so the double-tap closure handed to `AppModel.doubleTapInterceptor` always mutates the
/// LIVE state rather than a stale value-type snapshot from whichever render captured it.
@MainActor
final class ActiveTrainingController: ObservableObject {
    /// UserDefaults key for the "less sensitive" double-tap toggle, read here and written by a
    /// plain `@AppStorage` Toggle on `TrainingView` — kept as one shared key so both sides agree.
    static let robustDoubleTapKey = "strengthRobustDoubleTap"
    /// UserDefaults key for the configurable rest-timer target (seconds), same sharing pattern.
    static let restTargetSecondsKey = "strengthRestTargetSeconds"
    static let defaultRestTargetSeconds = 90

    @Published private(set) var session: StrengthSessionRow
    @Published private(set) var sets: [StrengthSetRow] = []
    @Published var exerciseNames: [String] = []
    @Published var selectedExercise: String?
    /// nil = no set currently running; otherwise the `Date` the set started (double-tap or manual).
    @Published private(set) var setStartedAt: Date?
    /// A just-ended set awaiting reps/weight confirmation — drives `LogSetSheet`. nil = sheet closed.
    @Published var pendingSet: PendingSet?

    struct PendingSet: Identifiable {
        let id = UUID()
        let exerciseName: String
        let setIndex: Int
        let durationS: Double
        let restBeforeS: Double?
        let defaultWeightKg: Double?
        let defaultReps: Int?
    }

    private let repo: Repository
    private let model: AppModel
    /// The template this session was started from, if any — seeds `exerciseNames`/per-set targets
    /// and receives the actually-achieved values back when the training ends (see `endTraining()`).
    private let template: StrengthTemplateRow?
    private var lastToggleAt: Date = .distantPast
    /// Exercises the rest-timer buzz has already fired for during the CURRENT rest period — cleared
    /// when a new set starts for that exercise, so the buzz fires once per rest, not once per second.
    private var restBuzzedExercises: Set<String> = []

    init(session: StrengthSessionRow, repo: Repository, model: AppModel, template: StrengthTemplateRow? = nil) {
        self.session = session
        self.repo = repo
        self.model = model
        self.template = template
    }

    func load() async {
        sets = await repo.strengthSets(sessionId: session.id)
        // Distinct logged names, first-appearance order (sets are already oldest-first).
        var seen = Set<String>()
        let loggedNames = sets.map(\.exerciseName).filter { seen.insert($0).inserted }
        // Union, not replace: start from the template's full plan (so an exercise with zero sets
        // logged so far never disappears the moment a DIFFERENT exercise gets its first set — the
        // previous version reassigned exerciseNames to just `loggedNames` here, which silently
        // dropped every not-yet-started planned exercise from the chip row), keep anything the user
        // already added manually (`addExercise`), then append any logged name not otherwise present
        // (an ad-hoc exercise/extra addition).
        var merged = template?.plan.map(\.exerciseName) ?? []
        for name in exerciseNames where !merged.contains(name) { merged.append(name) }
        for name in loggedNames where !merged.contains(name) { merged.append(name) }
        exerciseNames = merged
        if selectedExercise == nil { selectedExercise = exerciseNames.first }
    }

    func addExercise(_ name: String) {
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return }
        if !exerciseNames.contains(trimmed) { exerciseNames.append(trimmed) }
        selectedExercise = trimmed
    }

    /// Sets logged so far for one exercise in this session, oldest first.
    func sets(for exerciseName: String) -> [StrengthSetRow] {
        sets.filter { $0.exerciseName == exerciseName }.sorted { $0.completedAt < $1.completedAt }
    }

    /// The rest clock's anchor: when the last set for `exerciseName` ended, or nil if none yet.
    func lastSetEndedAt(for exerciseName: String) -> Date? {
        sets(for: exerciseName).last.map { Date(timeIntervalSince1970: TimeInterval($0.completedAt)) }
    }

    /// The template's planned target for the NEXT set of `exerciseName` (i.e. set index
    /// `sets(for: exerciseName).count`), if a template is active and still has a slot at that index.
    func nextTarget(for exerciseName: String) -> TemplateSetPlan? {
        guard let template else { return nil }
        let nextIndex = sets(for: exerciseName).count
        guard let plan = template.plan.first(where: { $0.exerciseName == exerciseName }),
              plan.sets.indices.contains(nextIndex) else { return nil }
        return plan.sets[nextIndex]
    }

    /// True once every planned set for this exercise has been logged. Always false without a
    /// template (there's no target to be "done" against for a blank/ad-hoc exercise).
    func isComplete(_ exerciseName: String) -> Bool {
        guard let template,
              let plan = template.plan.first(where: { $0.exerciseName == exerciseName }),
              !plan.sets.isEmpty else { return false }
        return sets(for: exerciseName).count >= plan.sets.count
    }

    /// A short "Set 2 of 3 — target 10 reps @ 60 kg" style hint for the active-exercise card, nil
    /// when there's no template (or the plan has no more slots for this exercise).
    func targetHint(for exerciseName: String) -> String? {
        guard let template,
              let plan = template.plan.first(where: { $0.exerciseName == exerciseName }) else { return nil }
        let nextIndex = sets(for: exerciseName).count
        guard plan.sets.indices.contains(nextIndex) else { return nil }
        let target = plan.sets[nextIndex]
        var parts: [String] = []
        if let reps = target.targetReps { parts.append("\(reps) reps") }
        if let weight = target.targetWeightKg { parts.append(String(format: "%.1f kg", weight)) }
        let targetText = parts.isEmpty ? "" : " — target \(parts.joined(separator: " @ "))"
        return "Set \(nextIndex + 1) of \(plan.sets.count)\(targetText)"
    }

    /// Handles a set start/stop — called by BOTH the manual button and the strap double-tap
    /// (via `AppModel.doubleTapInterceptor`). Always returns true while this controller is the
    /// active interceptor, so the tap never falls through to the user's configured double-tap action.
    ///
    /// Two noise guards, since the app only ever sees a fired "double-tap" event with no raw motion
    /// data to threshold on (the gesture recognizer itself lives in the strap's firmware, out of
    /// reach from here): an extra debounce on top of `AppModel`'s own 1.2s (longer when the user has
    /// turned on "less sensitive"), and a minimum plausible set duration — an end-tap arriving less
    /// than 1.5s after the start-tap is far more likely to be a second false trigger from the same
    /// hard rep than a real (impossibly short) completed set, so it's dropped rather than logged.
    @discardableResult
    func toggleSet() -> Bool {
        let now = Date()
        let debounce: TimeInterval = UserDefaults.standard.bool(forKey: Self.robustDoubleTapKey) ? 2.5 : 1.0
        guard now.timeIntervalSince(lastToggleAt) > debounce else { return true }

        guard let exercise = selectedExercise else { return true }

        if let startedAt = setStartedAt {
            // Noise guard: an implausibly short "set" is almost certainly a second false trigger from
            // the same movement, not a real end-tap. Leave the set running and ignore it silently.
            guard now.timeIntervalSince(startedAt) >= 1.5 else { return true }

            lastToggleAt = now
            setStartedAt = nil
            let duration = now.timeIntervalSince(startedAt)
            let restBefore = lastSetEndedAt(for: exercise).map { startedAt.timeIntervalSince($0) }
            let target = nextTarget(for: exercise)
            let lastSet = sets(for: exercise).last
            pendingSet = PendingSet(
                exerciseName: exercise,
                setIndex: sets(for: exercise).count,
                durationS: duration,
                restBeforeS: restBefore,
                defaultWeightKg: target?.targetWeightKg ?? lastSet?.weightKg,
                defaultReps: target?.targetReps ?? lastSet?.reps
            )
            buzzSetEnded()
        } else {
            lastToggleAt = now
            setStartedAt = now
            restBuzzedExercises.remove(exercise)
            buzzSetStarted()
        }
        return true
    }

    /// Called once a second (from the active-exercise card's own `TimelineView` tick — no separate
    /// timer needed) while resting: once the elapsed rest crosses the configured target, fires a
    /// single medium buzz as a "start your next set" nudge. Fires at most once per rest period.
    func checkRestBuzz(for exerciseName: String, now: Date) {
        guard setStartedAt == nil, selectedExercise == exerciseName,
              !restBuzzedExercises.contains(exerciseName),
              let lastEnd = lastSetEndedAt(for: exerciseName) else { return }
        let target = UserDefaults.standard.object(forKey: Self.restTargetSecondsKey) as? Int ?? Self.defaultRestTargetSeconds
        guard now.timeIntervalSince(lastEnd) >= TimeInterval(target) else { return }
        restBuzzedExercises.insert(exerciseName)
        model.buzz(loops: 3)
    }

    /// Confirms a just-ended set with the reps/weight the user entered, then reloads. Takes the
    /// `PendingSet` explicitly rather than re-reading `self.pendingSet` — `LogSetSheet`'s own Save
    /// button calls `dismiss()` right after kicking off this call, and for an `item`-bound sheet that
    /// dismiss nils out the bound `pendingSet` on the same actor turn; re-reading `pendingSet` here
    /// races that nil-out and can see it already cleared, silently dropping the set (the bug behind
    /// "set 2 never gets logged, the plan stays stuck offering set 1 forever").
    func confirmPendingSet(_ pending: PendingSet, reps: Int?, weightKg: Double?) async {
        pendingSet = nil
        let row = StrengthSetRow(
            id: UUID().uuidString, deviceId: WhoopStore.strengthLogSourceId, sessionId: session.id,
            exerciseName: pending.exerciseName, setIndex: pending.setIndex, reps: reps,
            weightKg: weightKg, setDurationS: pending.durationS, restBeforeS: pending.restBeforeS,
            completedAt: Int(Date().timeIntervalSince1970)
        )
        await repo.logStrengthSet(row)
        await load()
        advanceIfComplete(pending.exerciseName)
    }

    /// Once the just-logged exercise has every planned set done, jump to the next incomplete one in
    /// order — but only if the user is still looking at the exercise that just got completed (they
    /// may have already switched away manually while the confirm sheet was open).
    private func advanceIfComplete(_ exerciseName: String) {
        guard isComplete(exerciseName), selectedExercise == exerciseName else { return }
        if let next = exerciseNames.first(where: { $0 != exerciseName && !isComplete($0) }) {
            selectedExercise = next
        }
    }

    func discardPendingSet() {
        pendingSet = nil
    }

    func deleteSet(_ set: StrengthSetRow) async {
        await repo.deleteStrengthSet(id: set.id)
        await load()
    }

    func endTraining() async {
        var ended = session
        ended.endTs = Int(Date().timeIntervalSince1970)
        session = ended
        await repo.saveStrengthSession(ended)
        await writeBackTemplateIfNeeded()
    }

    /// Deletes the session (and every set logged in it) instead of ending it — no template
    /// write-back, since nothing about this training should count.
    func discardTraining() async {
        await repo.deleteStrengthSession(id: session.id)
    }

    /// Auto-learning: fold what was ACTUALLY achieved this session back into the template's plan, so
    /// next time it opens pre-filled with the latest numbers instead of going stale. A planned set
    /// that was never logged (skipped) keeps its old target untouched; sets logged beyond what the
    /// plan had are appended, so an ad-hoc extra set (or a whole ad-hoc exercise) grows the plan
    /// rather than being silently dropped.
    private func writeBackTemplateIfNeeded() async {
        guard var template else { return }
        var plan = template.plan
        for exercise in exerciseNames {
            let achieved = sets(for: exercise)
            guard !achieved.isEmpty else { continue }
            if let idx = plan.firstIndex(where: { $0.exerciseName == exercise }) {
                for (i, set) in achieved.enumerated() {
                    let updated = TemplateSetPlan(targetReps: set.reps, targetWeightKg: set.weightKg)
                    if plan[idx].sets.indices.contains(i) {
                        plan[idx].sets[i] = updated
                    } else {
                        plan[idx].sets.append(updated)
                    }
                }
            } else {
                plan.append(TemplateExercisePlan(
                    exerciseName: exercise,
                    sets: achieved.map { TemplateSetPlan(targetReps: $0.reps, targetWeightKg: $0.weightKg) }
                ))
            }
        }
        template.planJSON = StrengthTemplateRow.encode(plan)
        template.updatedAt = Int(Date().timeIntervalSince1970)
        await repo.saveTemplate(template)
    }

    // MARK: - Haptic feedback

    private func buzzSetStarted() {
        model.buzz(loops: 5)
    }

    private func buzzSetEnded() {
        model.buzz(loops: 1)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) { [model] in
            model.buzz(loops: 1)
        }
    }
}
