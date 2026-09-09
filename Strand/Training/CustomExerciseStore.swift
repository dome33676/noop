import Foundation
import WhoopStore

/// The user's own custom exercises — remembered globally once added, so a name typed for one
/// template/backfill/live-add shows up as a pickable suggestion everywhere else too, instead of
/// needing to be retyped. `Repository.strengthSets(exerciseName:)` and every progression/PR/volume
/// stat already match by the exact `exerciseName` string across ALL sessions and templates — the
/// stats were never "per template", but retyping a custom name slightly differently each time (a
/// missed dash, different casing) silently fragments them into what looks like separate exercises.
/// Picking a name once from here and reusing it is what keeps that history genuinely one exercise.
enum CustomExerciseStore {
    private static let key = "training.customExercises"

    /// All remembered custom exercise names, alphabetical.
    static func all() -> [String] {
        (UserDefaults.standard.stringArray(forKey: key) ?? []).sorted()
    }

    /// Remembers `name` if it's new — case-insensitively, against both the custom list AND the
    /// built-in `ExerciseCatalog` (no point remembering a duplicate of a suggestion that already
    /// exists). A no-op for a blank name or one already known either way.
    static func remember(_ name: String) {
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty, ExerciseCatalog.exercise(named: trimmed) == nil else { return }
        var current = all()
        guard !current.contains(where: { $0.caseInsensitiveCompare(trimmed) == .orderedSame }) else { return }
        current.append(trimmed)
        UserDefaults.standard.set(current, forKey: key)
    }

    private static let backfillDoneKey = "training.customExerciseBackfillDone"

    /// One-time backfill: remembers every exercise name already used in a LOGGED SET or a SAVED
    /// TEMPLATE, so history that predates this store's existence (every custom name typed before
    /// today) still becomes a global suggestion instead of only names typed from now on. Runs at
    /// most once ever (a UserDefaults flag), so it's safe to call unconditionally on every Training
    /// tab open — after the first run it's just a flag check.
    static func backfillIfNeeded(repo: Repository) async {
        guard !UserDefaults.standard.bool(forKey: backfillDoneKey) else { return }
        let logged = await repo.distinctLoggedExerciseNames()
        let planned = await repo.strengthTemplates().flatMap { $0.plan.map(\.exerciseName) }
        for name in Set(logged + planned) { remember(name) }
        UserDefaults.standard.set(true, forKey: backfillDoneKey)
    }
}
