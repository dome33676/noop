import XCTest
import GRDB
@testable import WhoopStore

final class FoodStoreTests: XCTestCase {

    // MARK: - v42 migration (additive: two new tables + indexes, nothing else dropped)

    func testV42CreatesFoodTables() async throws {
        let store = try await WhoopStore.inMemory()
        let tables = try await store.tableNames()
        XCTAssertTrue(tables.contains("foodItem"))
        XCTAssertTrue(tables.contains("mealEntry"))

        XCTAssertEqual(try await store.primaryKeyColumns("foodItem"), ["id"])
        XCTAssertEqual(try await store.primaryKeyColumns("mealEntry"), ["id"])

        let foodCols = try await store.columnNamesForTest(table: "foodItem")
        for c in ["id", "deviceId", "name", "kcalPer100g", "proteinPer100g", "carbsPer100g",
                  "fatPer100g", "barcode", "createdAt"] {
            XCTAssertTrue(foodCols.contains(c), "foodItem missing column \(c)")
        }

        let mealCols = try await store.columnNamesForTest(table: "mealEntry")
        for c in ["id", "deviceId", "foodItemId", "day", "mealType", "quantityGrams", "loggedAt"] {
            XCTAssertTrue(mealCols.contains(c), "mealEntry missing column \(c)")
        }
    }

    func testV42CreatesIndexes() async throws {
        let store = try await WhoopStore.inMemory()
        let foodIdx = try await store.indexNamesForTest(table: "foodItem")
        XCTAssertTrue(foodIdx.contains("idx_foodItem_device_name"))

        let mealIdx = try await store.indexNamesForTest(table: "mealEntry")
        XCTAssertTrue(mealIdx.contains("idx_mealEntry_device_day"))
        XCTAssertTrue(mealIdx.contains("idx_mealEntry_foodItem"))
    }

    /// Additive: v42 must not drop any table that existed before it.
    func testV42IsAdditive() async throws {
        let store = try await WhoopStore.inMemory()
        let tables = try await store.tableNames()
        for t in ["device", "workout", "journal", "labMarker", "metricSeries"] {
            XCTAssertTrue(tables.contains(t), "v42 must not drop \(t)")
        }
    }

    func testSchemaVersionIs19() {
        XCTAssertEqual(WhoopStoreInfo.schemaVersion, 20)
    }

    // MARK: - helpers

    private func mkItem(
        id: String, name: String, kcal: Double? = 100, protein: Double? = 5,
        carbs: Double? = 10, fat: Double? = 2, barcode: String? = nil, createdAt: Int = 1_740_000_000
    ) -> FoodItemRow {
        FoodItemRow(id: id, deviceId: WhoopStore.foodLogSourceId, name: name,
                    kcalPer100g: kcal, proteinPer100g: protein, carbsPer100g: carbs,
                    fatPer100g: fat, barcode: barcode, createdAt: createdAt)
    }

    private func mkEntry(
        id: String, foodItemId: String, day: String, mealType: String = "breakfast",
        grams: Double = 100, loggedAt: Int = 1_740_000_100
    ) -> MealEntryRow {
        MealEntryRow(id: id, deviceId: WhoopStore.foodLogSourceId, foodItemId: foodItemId,
                     day: day, mealType: mealType, quantityGrams: grams, loggedAt: loggedAt)
    }

    // MARK: - food library CRUD

    func testUpsertAndReadFoodItems() async throws {
        let store = try await WhoopStore.inMemory()
        try await store.upsertFoodItem(mkItem(id: "a", name: "Oats", createdAt: 1))
        try await store.upsertFoodItem(mkItem(id: "b", name: "Banana", createdAt: 2))

        let all = try await store.foodItems(deviceId: WhoopStore.foodLogSourceId)
        XCTAssertEqual(all.map(\.name), ["Banana", "Oats"], "most-recently-created first")
    }

    func testUpsertByIdUpdatesInPlace() async throws {
        let store = try await WhoopStore.inMemory()
        try await store.upsertFoodItem(mkItem(id: "a", name: "Oats", kcal: 100))
        try await store.upsertFoodItem(mkItem(id: "a", name: "Oats (corrected)", kcal: 389))

        let all = try await store.foodItems(deviceId: WhoopStore.foodLogSourceId)
        XCTAssertEqual(all.count, 1, "same id must not duplicate")
        XCTAssertEqual(all[0].name, "Oats (corrected)")
        XCTAssertEqual(all[0].kcalPer100g, 389)
    }

    func testSearchFoodItemsCaseInsensitive() async throws {
        let store = try await WhoopStore.inMemory()
        try await store.upsertFoodItem(mkItem(id: "a", name: "Chicken Breast"))
        try await store.upsertFoodItem(mkItem(id: "b", name: "Banana"))

        let results = try await store.searchFoodItems(deviceId: WhoopStore.foodLogSourceId, query: "chick")
        XCTAssertEqual(results.map(\.name), ["Chicken Breast"])
    }

    func testSearchFoodItemsEscapesLikeWildcards() async throws {
        let store = try await WhoopStore.inMemory()
        try await store.upsertFoodItem(mkItem(id: "a", name: "100% Whole Wheat"))
        try await store.upsertFoodItem(mkItem(id: "b", name: "10025 Wheat"))

        // A literal "%" in the query must not act as a wildcard.
        let results = try await store.searchFoodItems(deviceId: WhoopStore.foodLogSourceId, query: "100%")
        XCTAssertEqual(results.map(\.name), ["100% Whole Wheat"])
    }

    func testDeleteFoodItem() async throws {
        let store = try await WhoopStore.inMemory()
        try await store.upsertFoodItem(mkItem(id: "a", name: "Oats"))
        let deleted = try await store.deleteFoodItem(id: "a")
        XCTAssertTrue(deleted)
        let all = try await store.foodItems(deviceId: WhoopStore.foodLogSourceId)
        XCTAssertEqual(all.count, 0)
    }

    // MARK: - meal log + projection into metricSeries

    func testLogMealProjectsScaledTotalsToMetricSeries() async throws {
        let store = try await WhoopStore.inMemory()
        // 100 kcal / 5g protein / 10g carbs / 2g fat PER 100g.
        try await store.upsertFoodItem(mkItem(id: "oats", name: "Oats", kcal: 100, protein: 5, carbs: 10, fat: 2))
        // Logging 200g should scale everything ×2.
        try await store.logMeal(mkEntry(id: "m1", foodItemId: "oats", day: "2026-01-10", grams: 200))

        let kcal = try await store.metricSeries(deviceId: WhoopStore.foodLogSourceId,
                                                key: "food_calories_in_kcal", from: "2026-01-01", to: "2026-12-31")
        XCTAssertEqual(kcal.map(\.value), [200])
        let protein = try await store.metricSeries(deviceId: WhoopStore.foodLogSourceId,
                                                    key: "food_protein_g", from: "2026-01-01", to: "2026-12-31")
        XCTAssertEqual(protein.map(\.value), [10])
    }

    func testLogMealSumsMultipleEntriesOnSameDay() async throws {
        let store = try await WhoopStore.inMemory()
        try await store.upsertFoodItem(mkItem(id: "oats", name: "Oats", kcal: 100, protein: 5, carbs: 10, fat: 2))
        try await store.upsertFoodItem(mkItem(id: "banana", name: "Banana", kcal: 90, protein: 1, carbs: 23, fat: 0.3))

        try await store.logMeal(mkEntry(id: "m1", foodItemId: "oats", day: "2026-01-10", grams: 100))
        try await store.logMeal(mkEntry(id: "m2", foodItemId: "banana", day: "2026-01-10", grams: 100))

        let kcal = try await store.metricSeries(deviceId: WhoopStore.foodLogSourceId,
                                                key: "food_calories_in_kcal", from: "2026-01-01", to: "2026-12-31")
        XCTAssertEqual(kcal.map(\.value), [190], "same-day entries sum, not overwrite")
    }

    func testMealEntriesForDayOrderedByLoggedAt() async throws {
        let store = try await WhoopStore.inMemory()
        try await store.upsertFoodItem(mkItem(id: "oats", name: "Oats"))
        try await store.logMeal(mkEntry(id: "m2", foodItemId: "oats", day: "2026-01-10", loggedAt: 200))
        try await store.logMeal(mkEntry(id: "m1", foodItemId: "oats", day: "2026-01-10", loggedAt: 100))

        let entries = try await store.mealEntries(deviceId: WhoopStore.foodLogSourceId, day: "2026-01-10")
        XCTAssertEqual(entries.map(\.id), ["m1", "m2"], "oldest first")
    }

    func testDeleteMealEntryReprojectsRemainder() async throws {
        let store = try await WhoopStore.inMemory()
        try await store.upsertFoodItem(mkItem(id: "oats", name: "Oats", kcal: 100, protein: 5, carbs: 10, fat: 2))
        try await store.upsertFoodItem(mkItem(id: "banana", name: "Banana", kcal: 90, protein: 1, carbs: 23, fat: 0.3))
        try await store.logMeal(mkEntry(id: "m1", foodItemId: "oats", day: "2026-01-10", grams: 100))
        try await store.logMeal(mkEntry(id: "m2", foodItemId: "banana", day: "2026-01-10", grams: 100))

        let deleted = try await store.deleteMealEntry(id: "m1")
        XCTAssertTrue(deleted)

        let kcal = try await store.metricSeries(deviceId: WhoopStore.foodLogSourceId,
                                                key: "food_calories_in_kcal", from: "2026-01-01", to: "2026-12-31")
        XCTAssertEqual(kcal.map(\.value), [90], "remaining entry re-projects alone")
    }

    func testDeleteLastMealEntryRemovesProjectedDay() async throws {
        let store = try await WhoopStore.inMemory()
        try await store.upsertFoodItem(mkItem(id: "oats", name: "Oats"))
        try await store.logMeal(mkEntry(id: "m1", foodItemId: "oats", day: "2026-01-10"))
        _ = try await store.deleteMealEntry(id: "m1")

        let kcal = try await store.metricSeries(deviceId: WhoopStore.foodLogSourceId,
                                                key: "food_calories_in_kcal", from: "2026-01-01", to: "2026-12-31")
        XCTAssertEqual(kcal.count, 0, "no entries left for the day → projection removed, not stale")
    }
}
