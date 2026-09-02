import XCTest
import GRDB
@testable import WhoopStore

final class StrengthStoreTests: XCTestCase {

    // MARK: - v43 migration (additive: two new tables + indexes, nothing else dropped)

    func testV43CreatesStrengthTables() async throws {
        let store = try await WhoopStore.inMemory()
        let tables = try await store.tableNames()
        XCTAssertTrue(tables.contains("strengthSession"))
        XCTAssertTrue(tables.contains("strengthSet"))

        XCTAssertEqual(try await store.primaryKeyColumns("strengthSession"), ["id"])
        XCTAssertEqual(try await store.primaryKeyColumns("strengthSet"), ["id"])

        let sessionCols = try await store.columnNamesForTest(table: "strengthSession")
        for c in ["id", "deviceId", "name", "startTs", "endTs", "notes"] {
            XCTAssertTrue(sessionCols.contains(c), "strengthSession missing column \(c)")
        }

        let setCols = try await store.columnNamesForTest(table: "strengthSet")
        for c in ["id", "deviceId", "sessionId", "exerciseName", "setIndex", "reps", "weightKg",
                  "setDurationS", "restBeforeS", "completedAt"] {
            XCTAssertTrue(setCols.contains(c), "strengthSet missing column \(c)")
        }
    }

    func testV43CreatesIndexes() async throws {
        let store = try await WhoopStore.inMemory()
        let sessionIdx = try await store.indexNamesForTest(table: "strengthSession")
        XCTAssertTrue(sessionIdx.contains("idx_strengthSession_device_start"))

        let setIdx = try await store.indexNamesForTest(table: "strengthSet")
        XCTAssertTrue(setIdx.contains("idx_strengthSet_device_session"))
        XCTAssertTrue(setIdx.contains("idx_strengthSet_device_exercise"))
    }

    func testV43IsAdditive() async throws {
        let store = try await WhoopStore.inMemory()
        let tables = try await store.tableNames()
        for t in ["device", "workout", "journal", "foodItem", "mealEntry", "metricSeries"] {
            XCTAssertTrue(tables.contains(t), "v43 must not drop \(t)")
        }
    }

    func testSchemaVersionIs20() {
        XCTAssertEqual(WhoopStoreInfo.schemaVersion, 22)
    }

    // MARK: - helpers

    private func mkSession(id: String, name: String = "Push Day", start: Int = 1_740_000_000,
                           end: Int? = nil) -> StrengthSessionRow {
        StrengthSessionRow(id: id, deviceId: WhoopStore.strengthLogSourceId, name: name,
                           startTs: start, endTs: end, notes: nil)
    }

    private func mkSet(id: String, sessionId: String, exercise: String = "Bench Press",
                       setIndex: Int = 0, reps: Int? = 8, weightKg: Double? = 60,
                       duration: Double? = 12, rest: Double? = 90,
                       completedAt: Int = 1_740_000_100) -> StrengthSetRow {
        StrengthSetRow(id: id, deviceId: WhoopStore.strengthLogSourceId, sessionId: sessionId,
                       exerciseName: exercise, setIndex: setIndex, reps: reps, weightKg: weightKg,
                       setDurationS: duration, restBeforeS: rest, completedAt: completedAt)
    }

    // MARK: - session CRUD

    func testUpsertAndReadSessions() async throws {
        let store = try await WhoopStore.inMemory()
        try await store.upsertStrengthSession(mkSession(id: "a", start: 1))
        try await store.upsertStrengthSession(mkSession(id: "b", start: 2))

        let sessions = try await store.strengthSessions(deviceId: WhoopStore.strengthLogSourceId,
                                                         from: 0, to: 1_000_000_000)
        XCTAssertEqual(sessions.map(\.id), ["b", "a"], "newest first")
    }

    func testUpsertByIdUpdatesInPlace() async throws {
        let store = try await WhoopStore.inMemory()
        try await store.upsertStrengthSession(mkSession(id: "a", name: "Push Day", end: nil))
        try await store.upsertStrengthSession(mkSession(id: "a", name: "Push Day", end: 1_740_003_600))

        let sessions = try await store.strengthSessions(deviceId: WhoopStore.strengthLogSourceId,
                                                         from: 0, to: 1_000_000_000_0)
        XCTAssertEqual(sessions.count, 1, "same id must not duplicate")
        XCTAssertEqual(sessions[0].endTs, 1_740_003_600, "ending the session updates in place")
    }

    func testDeleteSessionCascadesSets() async throws {
        let store = try await WhoopStore.inMemory()
        try await store.upsertStrengthSession(mkSession(id: "s1"))
        try await store.logStrengthSet(mkSet(id: "set1", sessionId: "s1"))

        let deleted = try await store.deleteStrengthSession(id: "s1")
        XCTAssertTrue(deleted)

        let sets = try await store.strengthSets(deviceId: WhoopStore.strengthLogSourceId, sessionId: "s1")
        XCTAssertEqual(sets.count, 0, "deleting a session removes its sets")
    }

    // MARK: - set logging

    func testLogAndReadSetsForSession() async throws {
        let store = try await WhoopStore.inMemory()
        try await store.upsertStrengthSession(mkSession(id: "s1"))
        try await store.logStrengthSet(mkSet(id: "set1", sessionId: "s1", setIndex: 0, completedAt: 100))
        try await store.logStrengthSet(mkSet(id: "set2", sessionId: "s1", setIndex: 1, completedAt: 200))

        let sets = try await store.strengthSets(deviceId: WhoopStore.strengthLogSourceId, sessionId: "s1")
        XCTAssertEqual(sets.map(\.id), ["set1", "set2"], "oldest first")
    }

    func testLogSetByIdUpdatesInPlace() async throws {
        let store = try await WhoopStore.inMemory()
        try await store.upsertStrengthSession(mkSession(id: "s1"))
        try await store.logStrengthSet(mkSet(id: "set1", sessionId: "s1", reps: 8, weightKg: 60))
        try await store.logStrengthSet(mkSet(id: "set1", sessionId: "s1", reps: 6, weightKg: 65))

        let sets = try await store.strengthSets(deviceId: WhoopStore.strengthLogSourceId, sessionId: "s1")
        XCTAssertEqual(sets.count, 1, "same id must not duplicate")
        XCTAssertEqual(sets[0].reps, 6)
        XCTAssertEqual(sets[0].weightKg, 65)
    }

    func testProgressionQueryAcrossSessionsOrderedByDate() async throws {
        let store = try await WhoopStore.inMemory()
        try await store.upsertStrengthSession(mkSession(id: "s1", start: 1))
        try await store.upsertStrengthSession(mkSession(id: "s2", start: 2))
        try await store.logStrengthSet(mkSet(id: "a", sessionId: "s1", exercise: "Squat",
                                             weightKg: 80, completedAt: 100))
        try await store.logStrengthSet(mkSet(id: "b", sessionId: "s2", exercise: "Squat",
                                             weightKg: 85, completedAt: 200))
        // A different exercise must not show up in Squat's progression.
        try await store.logStrengthSet(mkSet(id: "c", sessionId: "s2", exercise: "Bench Press",
                                             weightKg: 60, completedAt: 150))

        let progression = try await store.strengthSets(deviceId: WhoopStore.strengthLogSourceId,
                                                        exerciseName: "Squat")
        XCTAssertEqual(progression.map(\.weightKg), [80, 85], "oldest-first, only this exercise")
    }

    func testDeleteStrengthSet() async throws {
        let store = try await WhoopStore.inMemory()
        try await store.upsertStrengthSession(mkSession(id: "s1"))
        try await store.logStrengthSet(mkSet(id: "set1", sessionId: "s1"))

        let deleted = try await store.deleteStrengthSet(id: "set1")
        XCTAssertTrue(deleted)

        let sets = try await store.strengthSets(deviceId: WhoopStore.strengthLogSourceId, sessionId: "s1")
        XCTAssertEqual(sets.count, 0)
    }
}
