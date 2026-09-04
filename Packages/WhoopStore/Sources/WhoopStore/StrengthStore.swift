import Foundation
import GRDB

// MARK: - v43 store: Strength training (sessions + sets)
//
// StrengthStore.swift — GRDB CRUD over the `strengthSession` and `strengthSet` tables (migration
// v43), the source-of-truth for the Training tab.
//
// `strengthSession` is one logged training ("Push Day"), `strengthSet` is one logged set within it,
// referencing the session by id and carrying a free-text `exerciseName` (no library table — a
// suggestion catalog lives at the app layer, exactly like `WorkoutCatalog` does for `workout.sport`).
//
// Mirrors the established `FoodStore`/`LabMarkerStore` idiom: plain Codable row structs, raw `Row`
// fetch + manual decode, idempotent upserts by primary key, all GRDB work via the actor's
// `syncWrite`/`syncRead` helpers.

/// One training session. `endTs` is nil while the session is still active.
public struct StrengthSessionRow: Identifiable, Equatable, Codable, Sendable {
    public var id: String
    public var deviceId: String
    public var name: String
    public var startTs: Int      // epoch seconds
    public var endTs: Int?       // epoch seconds; nil = active
    public var notes: String?

    public init(id: String, deviceId: String, name: String, startTs: Int, endTs: Int?, notes: String?) {
        self.id = id
        self.deviceId = deviceId
        self.name = name
        self.startTs = startTs
        self.endTs = endTs
        self.notes = notes
    }

    static func decode(_ row: Row) -> StrengthSessionRow {
        StrengthSessionRow(
            id: row["id"], deviceId: row["deviceId"], name: row["name"],
            startTs: row["startTs"], endTs: row["endTs"], notes: row["notes"]
        )
    }
}

/// One logged set. `setIndex` orders sets within (sessionId, exerciseName); `setDurationS` is the
/// measured time between a double-tap set-start and set-end (or nil for a manually-logged set with
/// no timer running); `restBeforeS` is the time since the previous set in this exercise ended.
public struct StrengthSetRow: Identifiable, Equatable, Codable, Sendable {
    public var id: String
    public var deviceId: String
    public var sessionId: String
    public var exerciseName: String
    public var setIndex: Int
    public var reps: Int?
    public var weightKg: Double?
    public var setDurationS: Double?
    public var restBeforeS: Double?
    public var isWarmup: Bool
    public var effortValue: Double?     // the numeric rating; nil = not recorded
    public var effortScale: String?     // "rir" or "rpe"; nil = not recorded
    public var completedAt: Int   // epoch seconds

    public init(
        id: String, deviceId: String, sessionId: String, exerciseName: String, setIndex: Int,
        reps: Int?, weightKg: Double?, setDurationS: Double?, restBeforeS: Double?,
        isWarmup: Bool = false, effortValue: Double? = nil, effortScale: String? = nil, completedAt: Int
    ) {
        self.id = id
        self.deviceId = deviceId
        self.sessionId = sessionId
        self.exerciseName = exerciseName
        self.setIndex = setIndex
        self.reps = reps
        self.weightKg = weightKg
        self.setDurationS = setDurationS
        self.restBeforeS = restBeforeS
        self.isWarmup = isWarmup
        self.effortValue = effortValue
        self.effortScale = effortScale
        self.completedAt = completedAt
    }

    static func decode(_ row: Row) -> StrengthSetRow {
        StrengthSetRow(
            id: row["id"], deviceId: row["deviceId"], sessionId: row["sessionId"],
            exerciseName: row["exerciseName"], setIndex: row["setIndex"], reps: row["reps"],
            weightKg: row["weightKg"], setDurationS: row["setDurationS"],
            restBeforeS: row["restBeforeS"], isWarmup: row["isWarmup"],
            effortValue: row["effortValue"], effortScale: row["effortScale"],
            completedAt: row["completedAt"]
        )
    }
}

extension WhoopStore {

    /// The constant deviceId every strength row is written under — there's no real per-strap
    /// scoping for hand-logged training data, matching the `foodLogSourceId` convention.
    public static let strengthLogSourceId = "strength-log"

    // MARK: - Sessions

    @discardableResult
    public func upsertStrengthSession(_ session: StrengthSessionRow) async throws -> Int {
        try syncWrite { db in
            try db.execute(sql: """
                INSERT INTO strengthSession (id, deviceId, name, startTs, endTs, notes)
                VALUES (?, ?, ?, ?, ?, ?)
                ON CONFLICT(id) DO UPDATE SET
                    name = excluded.name,
                    startTs = excluded.startTs,
                    endTs = excluded.endTs,
                    notes = excluded.notes
                """, arguments: [
                    session.id, session.deviceId, session.name, session.startTs, session.endTs,
                    session.notes,
                ])
            return db.changesCount
        }
    }

    /// Sessions in [from, to] (by startTs), newest first.
    public func strengthSessions(deviceId: String, from: Int, to: Int) async throws -> [StrengthSessionRow] {
        try syncRead { db in
            try Row.fetchAll(db, sql: """
                SELECT * FROM strengthSession
                WHERE deviceId = ? AND startTs >= ? AND startTs <= ?
                ORDER BY startTs DESC
                """, arguments: [deviceId, from, to]).map(StrengthSessionRow.decode)
        }
    }

    @discardableResult
    public func deleteStrengthSession(id: String) async throws -> Bool {
        try syncWrite { db in
            try db.execute(sql: "DELETE FROM strengthSet WHERE sessionId = ?", arguments: [id])
            try db.execute(sql: "DELETE FROM strengthSession WHERE id = ?", arguments: [id])
            return db.changesCount > 0
        }
    }

    // MARK: - Sets

    @discardableResult
    public func logStrengthSet(_ set: StrengthSetRow) async throws -> Bool {
        try syncWrite { db in
            try db.execute(sql: """
                INSERT INTO strengthSet
                    (id, deviceId, sessionId, exerciseName, setIndex, reps, weightKg, setDurationS,
                     restBeforeS, isWarmup, effortValue, effortScale, completedAt)
                VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                ON CONFLICT(id) DO UPDATE SET
                    exerciseName = excluded.exerciseName,
                    setIndex = excluded.setIndex,
                    reps = excluded.reps,
                    weightKg = excluded.weightKg,
                    setDurationS = excluded.setDurationS,
                    restBeforeS = excluded.restBeforeS,
                    isWarmup = excluded.isWarmup,
                    effortValue = excluded.effortValue,
                    effortScale = excluded.effortScale,
                    completedAt = excluded.completedAt
                """, arguments: [
                    set.id, set.deviceId, set.sessionId, set.exerciseName, set.setIndex, set.reps,
                    set.weightKg, set.setDurationS, set.restBeforeS, set.isWarmup, set.effortValue,
                    set.effortScale, set.completedAt,
                ])
            return db.changesCount > 0
        }
    }

    /// All sets logged in one session, oldest first.
    public func strengthSets(deviceId: String, sessionId: String) async throws -> [StrengthSetRow] {
        try syncRead { db in
            try Row.fetchAll(db, sql: """
                SELECT * FROM strengthSet WHERE deviceId = ? AND sessionId = ?
                ORDER BY completedAt ASC
                """, arguments: [deviceId, sessionId]).map(StrengthSetRow.decode)
        }
    }

    /// Every logged set for one exercise across ALL sessions, oldest first — the progression chart's
    /// source data.
    public func strengthSets(deviceId: String, exerciseName: String) async throws -> [StrengthSetRow] {
        try syncRead { db in
            try Row.fetchAll(db, sql: """
                SELECT * FROM strengthSet WHERE deviceId = ? AND exerciseName = ?
                ORDER BY completedAt ASC
                """, arguments: [deviceId, exerciseName]).map(StrengthSetRow.decode)
        }
    }

    @discardableResult
    public func deleteStrengthSet(id: String) async throws -> Bool {
        try syncWrite { db in
            try db.execute(sql: "DELETE FROM strengthSet WHERE id = ?", arguments: [id])
            return db.changesCount > 0
        }
    }
}
