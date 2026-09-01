import Foundation

/// The named-exercise catalogue for the Training tab's exercise picker — an app-layer suggestion
/// set, not a whitelist, exactly matching `WorkoutCatalog`'s convention for sports. `exerciseName`
/// on a logged set is free text; the catalogue only powers autocomplete so a typed-but-uncatalogued
/// exercise still saves exactly as typed.
enum ExerciseCatalog {

    /// One selectable exercise. `name` is the verbatim stored/display label.
    struct Exercise: Identifiable, Hashable {
        let name: String
        var id: String { name }
    }

    static let all: [Exercise] = [
        Exercise(name: "Bench Press"),
        Exercise(name: "Incline Bench Press"),
        Exercise(name: "Overhead Press"),
        Exercise(name: "Push-Up"),
        Exercise(name: "Dip"),
        Exercise(name: "Squat"),
        Exercise(name: "Front Squat"),
        Exercise(name: "Deadlift"),
        Exercise(name: "Romanian Deadlift"),
        Exercise(name: "Hip Thrust"),
        Exercise(name: "Leg Press"),
        Exercise(name: "Leg Curl"),
        Exercise(name: "Leg Extension"),
        Exercise(name: "Calf Raise"),
        Exercise(name: "Barbell Row"),
        Exercise(name: "Seated Row"),
        Exercise(name: "Lat Pulldown"),
        Exercise(name: "Pull-Up"),
        Exercise(name: "Chin-Up"),
        Exercise(name: "Bicep Curl"),
        Exercise(name: "Tricep Extension"),
        Exercise(name: "Lateral Raise"),
        Exercise(name: "Plank"),
    ]

    static func exercise(named name: String) -> Exercise? {
        let q = name.trimmingCharacters(in: .whitespaces)
        return all.first { $0.name.caseInsensitiveCompare(q) == .orderedSame }
    }

    static func matching(_ query: String) -> [Exercise] {
        let q = query.trimmingCharacters(in: .whitespaces)
        guard !q.isEmpty else { return all }
        return all.filter { $0.name.range(of: q, options: .caseInsensitive) != nil }
    }
}
