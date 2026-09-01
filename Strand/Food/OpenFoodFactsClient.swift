import Foundation

/// Opt-in lookup against the free, public Open Food Facts API (world.openfoodfacts.org) — search by
/// name or fetch by barcode, so a food-library item can be pre-filled instead of typed by hand. This
/// is NOOP's fifth network exception (see docs/PRIVACY_SECURITY.md §1.1e): OFF is a third-party,
/// crowd-sourced product database, not a NOOP-operated service. Only the search term or barcode is
/// sent, over plain HTTPS, and nothing about the user, their WHOOP, or their food log goes with it.
/// OFF requires no API key.
///
/// Follows the `UpdateChecker` idiom: a single unauthenticated `URLSession.shared.data(for:)` GET,
/// a status-code guard, tolerant decoding, `nil`/`[]` on any failure rather than throwing — a failed
/// lookup should read as "no result", never crash the sheet that's waiting on it.
enum OpenFoodFactsClient {

    /// One product as OFF returns it, mapped onto the fields `FoodItemRow` needs. Per-100g macros are
    /// OFF's own convention (`nutriments.*_100g`), matching `FoodItemRow`'s per-100g storage exactly.
    struct Product: Equatable {
        let name: String
        let barcode: String?
        let kcalPer100g: Double?
        let proteinPer100g: Double?
        let carbsPer100g: Double?
        let fatPer100g: Double?
    }

    private static let searchEndpoint = "https://world.openfoodfacts.org/cgi/search.pl"
    private static let productEndpoint = "https://world.openfoodfacts.org/api/v2/product/"

    /// Search by free-text name. Returns at most `limit` products with a usable name; a request
    /// timeout, non-200, or malformed response yields an empty list rather than throwing.
    static func search(query: String, limit: Int = 20) async -> [Product] {
        var components = URLComponents(string: searchEndpoint)!
        components.queryItems = [
            URLQueryItem(name: "search_terms", value: query),
            URLQueryItem(name: "search_simple", value: "1"),
            URLQueryItem(name: "action", value: "process"),
            URLQueryItem(name: "json", value: "1"),
            URLQueryItem(name: "page_size", value: String(limit)),
        ]
        guard let url = components.url else { return [] }
        do {
            var req = URLRequest(url: url, timeoutInterval: 12)
            req.setValue("application/json", forHTTPHeaderField: "Accept")
            let (data, resp) = try await URLSession.shared.data(for: req)
            guard (resp as? HTTPURLResponse)?.statusCode == 200,
                  let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let products = json["products"] as? [[String: Any]] else { return [] }
            return products.compactMap(decode)
        } catch {
            return []
        }
    }

    /// Fetch one product by barcode (EAN/UPC). `nil` on a miss, timeout, or malformed response.
    static func lookup(barcode: String) async -> Product? {
        guard let url = URL(string: productEndpoint + barcode + ".json") else { return nil }
        do {
            var req = URLRequest(url: url, timeoutInterval: 12)
            req.setValue("application/json", forHTTPHeaderField: "Accept")
            let (data, resp) = try await URLSession.shared.data(for: req)
            guard (resp as? HTTPURLResponse)?.statusCode == 200,
                  let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                  json["status"] as? Int == 1,
                  let product = json["product"] as? [String: Any] else { return nil }
            return decode(product)
        } catch {
            return nil
        }
    }

    /// Map one OFF product dict onto `Product`. `nil` if it has no usable name — a nameless entry is
    /// not worth offering the user.
    private static func decode(_ product: [String: Any]) -> Product? {
        let name = (product["product_name"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let name, !name.isEmpty else { return nil }
        let nutriments = product["nutriments"] as? [String: Any] ?? [:]
        return Product(
            name: name,
            barcode: product["code"] as? String,
            kcalPer100g: nutriments["energy-kcal_100g"] as? Double,
            proteinPer100g: nutriments["proteins_100g"] as? Double,
            carbsPer100g: nutriments["carbohydrates_100g"] as? Double,
            fatPer100g: nutriments["fat_100g"] as? Double
        )
    }
}
