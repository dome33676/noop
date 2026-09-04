import XCTest
import GRDB
@testable import WhoopStore

final class TemplateStoreTests: XCTestCase {

    // MARK: - v44 migration (additive: one new table + index, nothing else dropped)

    func testV44CreatesTemplateTable() async throws {
        let store = try await WhoopStore.inMemory()
        let tables = try await store.tableNames()
        XCTAssertTrue(tables.contains("strengthTemplate"))
        XCTAssertEqual(try await store.primaryKeyColumns("strengthTemplate"), ["id"])

        let cols = try await store.columnNamesForTest(table: "strengthTemplate")
        for c in ["id", "deviceId", "name", "planJSON", "createdAt", "updatedAt"] {
            XCTAssertTrue(cols.contains(c), "strengthTemplate missing column \(c)")
        }
    }

    func testV44CreatesIndex() async throws {
        let store = try await WhoopStore.inMemory()
        let idx = try await store.indexNamesForTest(table: "strengthTemplate")
        XCTAssertTrue(idx.contains("idx_strengthTemplate_device"))
    }

    func testV44IsAdditive() async throws {
        let store = try await WhoopStore.inMemory()
        let tables = try await store.tableNames()
        for t in ["device", "workout", "strengthSession", "strengthSet", "foodItem"] {
            XCTAssertTrue(tables.contains(t), "v44 must not drop \(t)")
        }
    }

    func testSchemaVersionIs21() {
        XCTAssertEqual(WhoopStoreInfo.schemaVersion, 23)
    }

    // MARK: - v45 migration (additive: nullable rest-timer-target column on strengthTemplate)

    func testV45AddsRestTargetSecondsColumn() async throws {
        let store = try await WhoopStore.inMemory()
        let cols = try await store.columnNamesForTest(table: "strengthTemplate")
        XCTAssertTrue(cols.contains("restTargetSeconds"), "strengthTemplate missing v45 restTargetSeconds column")
    }

    // MARK: - CRUD

    private func mkTemplate(id: String, name: String = "Push Day", planJSON: String = "[]",
                            createdAt: Int = 1, updatedAt: Int = 1) -> StrengthTemplateRow {
        StrengthTemplateRow(id: id, deviceId: WhoopStore.strengthLogSourceId, name: name,
                            planJSON: planJSON, createdAt: createdAt, updatedAt: updatedAt)
    }

    func testUpsertAndReadTemplates() async throws {
        let store = try await WhoopStore.inMemory()
        try await store.upsertTemplate(mkTemplate(id: "a", updatedAt: 1))
        try await store.upsertTemplate(mkTemplate(id: "b", updatedAt: 2))

        let all = try await store.templates(deviceId: WhoopStore.strengthLogSourceId)
        XCTAssertEqual(all.map(\.id), ["b", "a"], "most-recently-updated first")
    }

    func testUpsertByIdUpdatesInPlace() async throws {
        let store = try await WhoopStore.inMemory()
        try await store.upsertTemplate(mkTemplate(id: "a", name: "Push Day", planJSON: "[]"))
        try await store.upsertTemplate(mkTemplate(id: "a", name: "Push Day v2", planJSON: "[{}]", updatedAt: 2))

        let all = try await store.templates(deviceId: WhoopStore.strengthLogSourceId)
        XCTAssertEqual(all.count, 1, "same id must not duplicate")
        XCTAssertEqual(all[0].name, "Push Day v2")
        XCTAssertEqual(all[0].planJSON, "[{}]")
    }

    func testDeleteTemplate() async throws {
        let store = try await WhoopStore.inMemory()
        try await store.upsertTemplate(mkTemplate(id: "a"))
        let deleted = try await store.deleteTemplate(id: "a")
        XCTAssertTrue(deleted)
        let all = try await store.templates(deviceId: WhoopStore.strengthLogSourceId)
        XCTAssertEqual(all.count, 0)
    }

    func testRestTargetSecondsRoundTripsThroughUpsertAndRead() async throws {
        let store = try await WhoopStore.inMemory()
        try await store.upsertTemplate(StrengthTemplateRow(
            id: "a", deviceId: WhoopStore.strengthLogSourceId, name: "Push Day", planJSON: "[]",
            createdAt: 1, updatedAt: 1, restTargetSeconds: 90
        ))

        let all = try await store.templates(deviceId: WhoopStore.strengthLogSourceId)
        XCTAssertEqual(all.count, 1)
        XCTAssertEqual(all[0].restTargetSeconds, 90)
    }
}
