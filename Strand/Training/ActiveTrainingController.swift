import Foundation
import WhoopStore

/// Owns the mutable state of one active training session — a reference type (not `@State` on the
/// screen) so the double-tap closure handed to `AppModel.doubleTapInterceptor` always mutates the
/// LIVE state rather than a stale value-type snapshot from whichever render captured it.
@MainActor
final class ActiveTrainingController: ObservableObject {
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

    init(session: StrengthSessionRow, repo: Repository, model: AppModel) {
        self.session = session
        self.repo = repo
        self.model = model
    }

    func load() async {
        sets = await repo.strengthSets(sessionId: session.id)
        // Distinct exercise names, first-appearance order (sets are already oldest-first).
        var seen = Set<String>()
        exerciseNames = sets.map(\.exerciseName).filter { seen.insert($0).inserted }
        if selectedExercise == nil { selectedExercise = exerciseNames.last }
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

    /// Handles a set start/stop — called by BOTH the manual button and the strap double-tap
    /// (via `AppModel.doubleTapInterceptor`). Always returns true while this controller is the
    /// active interceptor, so the tap never falls through to the user's configured double-tap action.
    @discardableResult
    func toggleSet() -> Bool {
        guard let exercise = selectedExercise else { return true }
        if let startedAt = setStartedAt {
            // End the running set.
            setStartedAt = nil
            let duration = Date().timeIntervalSince(startedAt)
            let restBefore = lastSetEndedAt(for: exercise).map { startedAt.timeIntervalSince($0) }
            let lastSet = sets(for: exercise).last
            pendingSet = PendingSet(
                exerciseName: exercise,
                setIndex: sets(for: exercise).count,
                durationS: duration,
                restBeforeS: restBefore,
                defaultWeightKg: lastSet?.weightKg,
                defaultReps: lastSet?.reps
            )
            buzzSetEnded()
        } else {
            setStartedAt = Date()
            buzzSetStarted()
        }
        return true
    }

    /// Confirms a just-ended set with the reps/weight the user entered, then reloads.
    func confirmPendingSet(reps: Int?, weightKg: Double?) async {
        guard let pending = pendingSet else { return }
        pendingSet = nil
        let row = StrengthSetRow(
            id: UUID().uuidString, deviceId: WhoopStore.strengthLogSourceId, sessionId: session.id,
            exerciseName: pending.exerciseName, setIndex: pending.setIndex, reps: reps,
            weightKg: weightKg, setDurationS: pending.durationS, restBeforeS: pending.restBeforeS,
            completedAt: Int(Date().timeIntervalSince1970)
        )
        await repo.logStrengthSet(row)
        await load()
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
