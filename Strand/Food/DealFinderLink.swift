import Foundation

// MARK: - Deal Finder — a quick-launch link to marktguru.de's own public deal search
//
// Deliberately NOT an in-app scraper: marktguru's AGB explicitly prohibits "der Einsatz von
// Computerprogrammen zum automatischen Auslesen von Daten" (automated/programmatic data extraction).
// Fetching their offers into NOOP would cross that. Opening their own public search page in the
// browser instead is just a human visiting their site — the "private consumption" their terms
// already permit — so this stays a plain link-out, never a background request.

enum DealFinderLink {
    static let enabledKey = "dealFinder.enabled"
    static let productKey = "dealFinder.product"

    /// marktguru's public search URL for a product — verified live: `/search/<query>` (a path
    /// segment, not a query param) renders real current offers with no auth needed.
    static func searchURL(for product: String) -> URL? {
        let trimmed = product.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty,
              let encoded = trimmed.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed)
        else { return nil }
        return URL(string: "https://www.marktguru.de/search/\(encoded)")
    }
}
