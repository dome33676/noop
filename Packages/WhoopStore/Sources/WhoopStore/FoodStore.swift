import Foundation
import GRDB

// MARK: - v42 store: Food tracking (library + meal log)
//
// FoodStore.swift — GRDB CRUD over the `foodItem` and `mealEntry` tables (migration
// v42), the source-of-truth for the Food tab's diary.
//
// `foodItem` is the reusable library (macros per 100g, user-editable, optionally seeded
// from an Open Food Facts lookup); `mealEntry` is the log, one row per logged quantity
// of a food item on a day. On every meal-entry write/delete this store recomputes that
// day's calorie/macro totals and upserts them into `metricSeries` under
// `WhoopStore.foodLogSourceId`, exactly as `LabMarkerStore` projects lab readings — so
// the existing Trends/Compare machinery picks up food totals with no extra plumbing.
//
// Mirrors the established `LabMarkerStore` idiom: plain Codable row structs, raw `Row`
// fetch + manual decode, idempotent upserts by primary key, all GRDB work via the
// actor's `syncWrite`/`syncRead` helpers.

/// One food-library entry. Macros are per 100g so any logged quantity can be scaled.
/// `barcode` is set when the item was seeded from an Open Food Facts lookup; nil for a
/// hand-entered item. All macro fields are nullable — a partially-known item (e.g. only
/// calories) is still usable.
public struct FoodItemRow: Equatable, Codable, Sendable {
    public var id: String
    public var deviceId: String
    public var name: String
    public var kcalPer100g: Double?
    public var proteinPer100g: Double?
    public var carbsPer100g: Double?
    public var fatPer100g: Double?
    public var barcode: String?
    public var createdAt: Int   // epoch seconds

    public init(
        id: String,
        deviceId: String,
        name: String,
        kcalPer100g: Double?,
        proteinPer100g: Double?,
        carbsPer100g: Double?,
        fatPer100g: Double?,
        barcode: String?,
        createdAt: Int
    ) {
        self.id = id
        self.deviceId = deviceId
        self.name = name
        self.kcalPer100g = kcalPer100g
        self.proteinPer100g = proteinPer100g
        self.carbsPer100g = carbsPer100g
        self.fatPer100g = fatPer100g
        self.barcode = barcode
        self.createdAt = createdAt
    }

    static func decode(_ row: Row) -> FoodItemRow {
        FoodItemRow(
            id: row["id"],
            deviceId: row["deviceId"],
            name: row["name"],
            kcalPer100g: row["kcalPer100g"],
            proteinPer100g: row["proteinPer100g"],
            carbsPer100g: row["carbsPer100g"],
            fatPer100g: row["fatPer100g"],
            barcode: row["barcode"],
            createdAt: row["createdAt"]
        )
    }
}

/// One logged quantity of a food item on a day. `foodItemId` references `FoodItemRow.id`
/// (no FK constraint — this schema stays flat, matching `workout`/`labMarker`).
public struct MealEntryRow: Identifiable, Equatable, Codable, Sendable {
    public var id: String
    public var deviceId: String
    public var foodItemId: String
    public var day: String            // yyyy-MM-dd
    public var mealType: String       // breakfast | lunch | dinner | snack
    public var quantityGrams: Double
    public var loggedAt: Int          // epoch seconds

    public init(
        id: String,
        deviceId: String,
        foodItemId: String,
        day: String,
        mealType: String,
        quantityGrams: Double,
        loggedAt: Int
    ) {
        self.id = id
        self.deviceId = deviceId
        self.foodItemId = foodItemId
        self.day = day
        self.mealType = mealType
        self.quantityGrams = quantityGrams
        self.loggedAt = loggedAt
    }

    static func decode(_ row: Row) -> MealEntryRow {
        MealEntryRow(
            id: row["id"],
            deviceId: row["deviceId"],
            foodItemId: row["foodItemId"],
            day: row["day"],
            mealType: row["mealType"],
            quantityGrams: row["quantityGrams"],
            loggedAt: row["loggedAt"]
        )
    }
}

extension WhoopStore {

    /// The constant deviceId every food row is written under (there's no real per-strap
    /// scoping for hand-entered nutrition), and the `metricSeries` source id the daily
    /// rollup is projected into. Matches the `labBookSourceId` convention.
    public static let foodLogSourceId = "food-log"

    // MARK: - Food library

    /// Upsert one food-library item by `id`. Returns rows changed.
    @discardableResult
    public func upsertFoodItem(_ item: FoodItemRow) async throws -> Int {
        try syncWrite { db in
            try db.execute(sql: """
                INSERT INTO foodItem
                    (id, deviceId, name, kcalPer100g, proteinPer100g, carbsPer100g, fatPer100g,
                     barcode, createdAt)
                VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)
                ON CONFLICT(id) DO UPDATE SET
                    name = excluded.name,
                    kcalPer100g = excluded.kcalPer100g,
                    proteinPer100g = excluded.proteinPer100g,
                    carbsPer100g = excluded.carbsPer100g,
                    fatPer100g = excluded.fatPer100g,
                    barcode = excluded.barcode
                """, arguments: [
                    item.id, item.deviceId, item.name, item.kcalPer100g, item.proteinPer100g,
                    item.carbsPer100g, item.fatPer100g, item.barcode, item.createdAt,
                ])
            return db.changesCount
        }
    }

    /// The full food library, most-recently-created first.
    public func foodItems(deviceId: String) async throws -> [FoodItemRow] {
        try syncRead { db in
            try Row.fetchAll(db, sql: """
                SELECT * FROM foodItem WHERE deviceId = ? ORDER BY createdAt DESC
                """, arguments: [deviceId]).map(FoodItemRow.decode)
        }
    }

    /// Case-insensitive name search over the library, for the meal-logging search field.
    public func searchFoodItems(deviceId: String, query: String) async throws -> [FoodItemRow] {
        try syncRead { db in
            try Row.fetchAll(db, sql: """
                SELECT * FROM foodItem
                WHERE deviceId = ? AND name LIKE ? ESCAPE '\\'
                ORDER BY name ASC
                """, arguments: [deviceId, "%\(query.escapedForLike)%"]).map(FoodItemRow.decode)
        }
    }

    /// Delete one food-library item. Existing meal entries referencing it are left as-is
    /// (their totals were already projected at log time) but will no longer resolve a
    /// name/macros in the UI — callers should warn before deleting an item still in use.
    @discardableResult
    public func deleteFoodItem(id: String) async throws -> Bool {
        try syncWrite { db in
            try db.execute(sql: "DELETE FROM foodItem WHERE id = ?", arguments: [id])
            return db.changesCount > 0
        }
    }

    // MARK: - Meal log

    /// Log (or edit, by re-passing the same `id`) one meal entry, then re-project that
    /// day's totals into `metricSeries`. Returns true if a row was written.
    @discardableResult
    public func logMeal(_ entry: MealEntryRow) async throws -> Bool {
        try syncWrite { db in
            try db.execute(sql: """
                INSERT INTO mealEntry
                    (id, deviceId, foodItemId, day, mealType, quantityGrams, loggedAt)
                VALUES (?, ?, ?, ?, ?, ?, ?)
                ON CONFLICT(id) DO UPDATE SET
                    foodItemId = excluded.foodItemId,
                    day = excluded.day,
                    mealType = excluded.mealType,
                    quantityGrams = excluded.quantityGrams,
                    loggedAt = excluded.loggedAt
                """, arguments: [
                    entry.id, entry.deviceId, entry.foodItemId, entry.day, entry.mealType,
                    entry.quantityGrams, entry.loggedAt,
                ])
            try self.reprojectDay(db, deviceId: entry.deviceId, day: entry.day)
            return db.changesCount > 0
        }
    }

    /// All meal entries for one day, oldest first.
    public func mealEntries(deviceId: String, day: String) async throws -> [MealEntryRow] {
        try syncRead { db in
            try Row.fetchAll(db, sql: """
                SELECT * FROM mealEntry WHERE deviceId = ? AND day = ? ORDER BY loggedAt ASC
                """, arguments: [deviceId, day]).map(MealEntryRow.decode)
        }
    }

    /// Delete one meal entry by id, then re-project its day's totals. Returns true if a
    /// row was deleted.
    @discardableResult
    public func deleteMealEntry(id: String) async throws -> Bool {
        try syncWrite { db in
            guard let row = try Row.fetchOne(db, sql:
                "SELECT * FROM mealEntry WHERE id = ?", arguments: [id]).map(MealEntryRow.decode) else {
                return false
            }
            try db.execute(sql: "DELETE FROM mealEntry WHERE id = ?", arguments: [id])
            try self.reprojectDay(db, deviceId: row.deviceId, day: row.day)
            return true
        }
    }

    // MARK: - Projection (private)

    /// Recompute (kcal/protein/carbs/fat) totals for one day from the CURRENT
    /// `mealEntry` + `foodItem` rows and upsert them into `metricSeries` under
    /// `foodLogSourceId`. A day with zero entries has its projected keys removed, so a
    /// fully-cleared day never leaves a stale total behind.
    private func reprojectDay(_ db: Database, deviceId: String, day: String) throws {
        let totals = try Row.fetchOne(db, sql: """
            SELECT
                SUM(m.quantityGrams / 100.0 * f.kcalPer100g)    AS kcal,
                SUM(m.quantityGrams / 100.0 * f.proteinPer100g) AS protein,
                SUM(m.quantityGrams / 100.0 * f.carbsPer100g)   AS carbs,
                SUM(m.quantityGrams / 100.0 * f.fatPer100g)     AS fat
            FROM mealEntry m
            JOIN foodItem f ON f.id = m.foodItemId
            WHERE m.deviceId = ? AND m.day = ?
            """, arguments: [deviceId, day])

        let cells: [(key: String, value: Double?)] = [
            ("food_calories_in_kcal", totals?["kcal"]),
            ("food_protein_g", totals?["protein"]),
            ("food_carbs_g", totals?["carbs"]),
            ("food_fat_g", totals?["fat"]),
        ]
        for cell in cells {
            if let v = cell.value {
                try db.execute(sql: """
                    INSERT INTO metricSeries (deviceId, day, key, value)
                    VALUES (?, ?, ?, ?)
                    ON CONFLICT(deviceId, day, key) DO UPDATE SET value = excluded.value
                    """, arguments: [WhoopStore.foodLogSourceId, day, cell.key, v])
            } else {
                try db.execute(sql: """
                    DELETE FROM metricSeries WHERE deviceId = ? AND day = ? AND key = ?
                    """, arguments: [WhoopStore.foodLogSourceId, day, cell.key])
            }
        }
    }
}

private extension String {
    /// Escape `%`/`_`/`\` for a `LIKE ... ESCAPE '\'` pattern, so a search query
    /// containing those characters is matched literally, not as a wildcard.
    var escapedForLike: String {
        replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "%", with: "\\%")
            .replacingOccurrences(of: "_", with: "\\_")
    }
}
