import Foundation
import WebKit

// MARK: - Deal Finder — current supermarket deals for a tracked product, scraped from marktguru.de
//
// marktguru's own product search (verified live) renders the exact shape of card the "Monster
// Finder" ad showed: price, retailer, validity window. Their AGB prohibits automated data
// extraction — the developer has explicitly accepted that tradeoff for this personal, single-user,
// low-volume (once every few days) use, so this fetches for real rather than only linking out.
//
// The public search page is a client-rendered SPA with no server-side data embedded in the raw
// HTML (confirmed: no __NEXT_DATA__/__NUXT__/__APOLLO_STATE__), so a plain URLSession GET only gets
// an empty shell — a headless `WKWebView` runs the SAME page a browser would, then reads the
// rendered offer cards straight out of the DOM (`li.offer-list-item` and its
// `.price`/`.valid`/`.retailer-name`/`.info` children — verified live against the real page).
@MainActor
final class DealFinderStore: ObservableObject {
    @Published private(set) var offers: [DealOffer] = []
    @Published private(set) var lastFetched: Date?
    @Published private(set) var lastError: String?
    @Published private(set) var isLoading = false

    private static let cacheKey = "dealFinder.cache.v1"
    private static let staleAfter: TimeInterval = 3 * 86_400   // German flyers run weekly

    init() {
        guard let data = UserDefaults.standard.data(forKey: Self.cacheKey),
              let cached = try? JSONDecoder().decode(CachedOffers.self, from: data) else { return }
        offers = cached.offers
        lastFetched = cached.fetchedAt
    }

    /// Refreshes only if the cache is stale (or empty) — call from `.task` on the card appearing.
    func refreshIfStale(product: String) async {
        if let lastFetched, Date().timeIntervalSince(lastFetched) < Self.staleAfter { return }
        await refresh(product: product)
    }

    func refresh(product: String) async {
        guard let url = DealFinderLink.searchURL(for: product) else { return }
        isLoading = true
        defer { isLoading = false }
        do {
            let scraped = try await Self.scrape(url: url)
            offers = scraped
            lastFetched = Date()
            lastError = nil
            if let blob = try? JSONEncoder().encode(CachedOffers(offers: scraped, fetchedAt: lastFetched!)) {
                UserDefaults.standard.set(blob, forKey: Self.cacheKey)
            }
        } catch {
            lastError = "Konnte gerade keine Angebote laden"
        }
    }

    /// Loads the page in a headless WKWebView, waits for its navigation to finish, then reads the
    /// offer cards straight out of the rendered DOM. `NavigationWaiter` is a plain, non-actor-isolated
    /// delegate so WKNavigationDelegate conformance never has to reconcile with @MainActor — it only
    /// signals completion; all the actual state lives on this store.
    private static func scrape(url: URL) async throws -> [DealOffer] {
        let webView = WKWebView(frame: .zero)
        let waiter = NavigationWaiter()
        webView.navigationDelegate = waiter
        webView.load(URLRequest(url: url))
        try await waiter.waitForFinish()
        // The offer list renders client-side after didFinish fires; a short settle gives the SPA's
        // own data fetch + render pass time to complete before the DOM read below.
        try? await Task.sleep(nanoseconds: 1_500_000_000)
        let js = """
        Array.from(document.querySelectorAll('li.offer-list-item')).map(li => ({
            store: li.querySelector('.retailer-name a')?.textContent?.trim() ?? '',
            price: li.querySelector('.price .price')?.textContent?.trim() ?? '',
            valid: li.querySelector('.valid')?.textContent?.trim() ?? '',
            info: li.querySelector('.info')?.textContent?.trim() ?? ''
        }))
        """
        guard let raw = try await webView.evaluateJavaScript(js) as? [[String: String]] else { return [] }
        return raw.compactMap(DealOffer.init).sorted { ($0.price ?? .infinity) < ($1.price ?? .infinity) }
    }

    private struct CachedOffers: Codable { let offers: [DealOffer]; let fetchedAt: Date }
}

/// Signals when a WKWebView's navigation finishes or fails — separated from `DealFinderStore` so
/// the delegate protocol conformance carries no actor annotation, only a continuation hand-off.
private final class NavigationWaiter: NSObject, WKNavigationDelegate {
    private var continuation: CheckedContinuation<Void, Error>?

    func waitForFinish() async throws {
        try await withCheckedThrowingContinuation { self.continuation = $0 }
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        continuation?.resume()
        continuation = nil
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        continuation?.resume(throwing: error)
        continuation = nil
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        continuation?.resume(throwing: error)
        continuation = nil
    }
}

/// One store's current offer for the tracked product, parsed from marktguru's rendered DOM text
/// (e.g. price "€ 8,88", valid "07.09. - 12.09.").
struct DealOffer: Identifiable, Codable, Equatable {
    let store: String
    let price: Double?
    let validFrom: Date?
    let validTo: Date?
    let info: String?

    var id: String { store + (validFrom?.description ?? "") }

    var validityLabel: String? {
        guard let from = validFrom, let to = validTo else { return nil }
        let f = DateFormatter()
        f.setLocalizedDateFormatFromTemplate("EE")
        return "\(f.string(from: from))–\(f.string(from: to))"
    }

    fileprivate init?(_ raw: [String: String]) {
        let store = (raw["store"] ?? "").trimmingCharacters(in: .whitespaces)
        guard !store.isEmpty else { return nil }
        self.store = store
        self.info = raw["info"]?.trimmingCharacters(in: .whitespaces)

        // "€ 8,88" -> 8.88. German-locale comma decimal, same normalization as everywhere else in
        // this app (mirrors JournalLogCard's NumericLogField).
        let priceDigits = (raw["price"] ?? "")
            .replacingOccurrences(of: "€", with: "")
            .trimmingCharacters(in: .whitespaces)
            .replacingOccurrences(of: ",", with: ".")
        self.price = Double(priceDigits)

        // "07.09. - 12.09." -> two dates. No year in the rendered text; assume the current year,
        // rolling the FROM date forward a year if it would otherwise land more than a couple months
        // in the past (the only way that happens is a validity window spanning a Dec->Jan boundary).
        let validParts = (raw["valid"] ?? "")
            .replacingOccurrences(of: "Gültig:", with: "")
            .components(separatedBy: "-")
            .map { $0.trimmingCharacters(in: .whitespaces) }
        if validParts.count == 2 {
            let cal = Calendar.current
            let year = cal.component(.year, from: Date())
            func parse(_ s: String, year: Int) -> Date? {
                let digits = s.split(separator: ".").compactMap { Int($0) }
                guard digits.count >= 2 else { return nil }
                return cal.date(from: DateComponents(year: year, month: digits[1], day: digits[0]))
            }
            var from = parse(validParts[0], year: year)
            let to = parse(validParts[1], year: year)
            if let f = from, f.timeIntervalSinceNow < -60 * 86_400 {
                from = parse(validParts[0], year: year + 1)
            }
            self.validFrom = from
            self.validTo = to
        } else {
            self.validFrom = nil
            self.validTo = nil
        }
    }
}
