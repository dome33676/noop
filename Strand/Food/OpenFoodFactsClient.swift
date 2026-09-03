import Foundation

/// Opt-in lookup against the free, public Open Food Facts API — search by name or fetch by barcode,
/// so a food-library item can be pre-filled instead of typed by hand. This is NOOP's fifth network
/// exception (see docs/PRIVACY_SECURITY.md §1.1e): OFF is a third-party, crowd-sourced product
/// database, not a NOOP-operated service. Only the search term or barcode is sent, over plain HTTPS,
/// and nothing about the user, their WHOOP, or their food log goes with it. OFF requires no API key.
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

    struct SearchPage {
        let products: [Product]
        let hasMore: Bool
    }

    // The legacy `world.openfoodfacts.org/cgi/search.pl` endpoint this used to call now regularly
    // answers with a 503 "temporarily unavailable" bot-wall instead of JSON, and even when it does
    // respond its plain substring matching treats a multi-word query as a literal AND across fields —
    // "Apfel Frucht" matched nothing because no product has both words, while "Apfel" alone matched
    // every product with "Apfel" anywhere in its name (Apfelsaft, Apfelmus, ...) with no relevance
    // ranking. `search.openfoodfacts.org` is OFF's current Elasticsearch-backed full-text search
    // (search-a-licious): real relevance ranking, sane multi-word handling, and real pagination via
    // page/page_size/page_count — verified directly against the live API before switching.
    private static let searchEndpoint = "https://search.openfoodfacts.org/search"
    private static let productEndpoint = "https://world.openfoodfacts.org/api/v2/product/"
    // OFF's API guidelines ask every client to identify itself; the old client sent no User-Agent at
    // all, which — together with the legacy endpoint's bot-wall — is a second plausible reason lookups
    // intermittently failed.
    private static let userAgent = "NOOP-iOS/1.0 (github.com/dome33676/noop)"

    /// One page of free-text results, oldest-relevance-first (OFF's own ranking). `page` is 1-based.
    /// A request timeout, non-200, or malformed response yields an empty, non-continuing page rather
    /// than throwing — a failed lookup should read as "no (more) results", never crash the caller.
    static func search(query: String, page: Int = 1, pageSize: Int = 20) async -> SearchPage {
        var components = URLComponents(string: searchEndpoint)!
        components.queryItems = [
            URLQueryItem(name: "q", value: query),
            URLQueryItem(name: "page", value: String(page)),
            URLQueryItem(name: "page_size", value: String(pageSize)),
            URLQueryItem(name: "fields", value: "product_name,code,nutriments"),
        ]
        guard let url = components.url else { return SearchPage(products: [], hasMore: false) }
        do {
            var req = URLRequest(url: url, timeoutInterval: 12)
            req.setValue("application/json", forHTTPHeaderField: "Accept")
            req.setValue(userAgent, forHTTPHeaderField: "User-Agent")
            let (data, resp) = try await URLSession.shared.data(for: req)
            guard (resp as? HTTPURLResponse)?.statusCode == 200,
                  let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let hits = json["hits"] as? [[String: Any]] else {
                return SearchPage(products: [], hasMore: false)
            }
            let pageCount = json["page_count"] as? Int ?? page
            return SearchPage(products: hits.compactMap(decode), hasMore: page < pageCount)
        } catch {
            return SearchPage(products: [], hasMore: false)
        }
    }

    /// Fetch one product by barcode (EAN/UPC). `nil` on a miss, timeout, or malformed response.
    static func lookup(barcode: String) async -> Product? {
        guard let url = URL(string: productEndpoint + barcode + ".json") else { return nil }
        do {
            var req = URLRequest(url: url, timeoutInterval: 12)
            req.setValue("application/json", forHTTPHeaderField: "Accept")
            req.setValue(userAgent, forHTTPHeaderField: "User-Agent")
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
