import Foundation
import GRDB

// MARK: - v44 store: Strength training templates
//
// TemplateStore.swift — GRDB CRUD over the `strengthTemplate` table (migration v44). `planJSON` is
// an opaque blob here — WhoopStore doesn't know or care what's inside it (see `Strand/Training/
// TemplatePlan.swift` at the app layer for the actual shape + encode/decode), matching how
// `workout.zonesJSON` is handled.

public struct StrengthTemplateRow: Identifiable, Equatable, Codable, Sendable {
    public var id: String
    public var deviceId: String
    public var name: String
    public var planJSON: String
    public var createdAt: Int
    public var updatedAt: Int
    public var restTargetSeconds: Int?

    public init(
        id: String, deviceId: String, name: String, planJSON: String, createdAt: Int, updatedAt: Int,
        restTargetSeconds: Int? = nil
    ) {
        self.id = id
        self.deviceId = deviceId
        self.name = name
        self.planJSON = planJSON
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.restTargetSeconds = restTargetSeconds
    }

    static func decode(_ row: Row) -> StrengthTemplateRow {
        StrengthTemplateRow(
            id: row["id"], deviceId: row["deviceId"], name: row["name"], planJSON: row["planJSON"],
            createdAt: row["createdAt"], updatedAt: row["updatedAt"], restTargetSeconds: row["restTargetSeconds"]
        )
    }
}

extension WhoopStore {

    @discardableResult
    public func upsertTemplate(_ template: StrengthTemplateRow) async throws -> Int {
        try syncWrite { db in
            try db.execute(sql: """
                INSERT INTO strengthTemplate (id, deviceId, name, planJSON, createdAt, updatedAt, restTargetSeconds)
                VALUES (?, ?, ?, ?, ?, ?, ?)
                ON CONFLICT(id) DO UPDATE SET
                    name = excluded.name,
                    planJSON = excluded.planJSON,
                    updatedAt = excluded.updatedAt,
                    restTargetSeconds = excluded.restTargetSeconds
                """, arguments: [
                    template.id, template.deviceId, template.name, template.planJSON,
                    template.createdAt, template.updatedAt, template.restTargetSeconds,
                ])
            return db.changesCount
        }
    }

    /// All templates, most-recently-updated first.
    public func templates(deviceId: String) async throws -> [StrengthTemplateRow] {
        try syncRead { db in
            try Row.fetchAll(db, sql: """
                SELECT * FROM strengthTemplate WHERE deviceId = ? ORDER BY updatedAt DESC
                """, arguments: [deviceId]).map(StrengthTemplateRow.decode)
        }
    }

    @discardableResult
    public func deleteTemplate(id: String) async throws -> Bool {
        try syncWrite { db in
            try db.execute(sql: "DELETE FROM strengthTemplate WHERE id = ?", arguments: [id])
            return db.changesCount > 0
        }
    }
}
