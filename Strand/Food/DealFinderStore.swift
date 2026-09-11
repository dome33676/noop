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

    private static let cacheKey = "dealFinder.cache.v2"   // v2: cache now also carries the PLZ it was fetched for
    private static let staleAfter: TimeInterval = 3 * 86_400   // German flyers run weekly

    /// The PLZ the current `offers` were actually fetched for — compared against the live Settings
    /// value in `refreshIfStale` so a PLZ change there isn't masked by an otherwise-fresh cache.
    private var lastFetchedPLZ: String?

    init() {
        guard let data = UserDefaults.standard.data(forKey: Self.cacheKey),
              let cached = try? JSONDecoder().decode(CachedOffers.self, from: data) else { return }
        offers = cached.offers
        lastFetched = cached.fetchedAt
        lastFetchedPLZ = cached.plz
    }

    /// Refreshes if the cache is stale (or empty), or if the PLZ in Settings has changed since the
    /// last fetch — otherwise a PLZ change sits inert until the cache naturally goes stale (up to
    /// `staleAfter`), since `scrape` only reads the PLZ while it actually runs.
    func refreshIfStale(product: String) async {
        let currentPLZ = (UserDefaults.standard.string(forKey: DealFinderLink.plzKey) ?? "")
            .filter(\.isNumber)
        let plzChanged = currentPLZ != (lastFetchedPLZ ?? "")
        if let lastFetched, !plzChanged, Date().timeIntervalSince(lastFetched) < Self.staleAfter { return }
        await refresh(product: product)
    }

    func refresh(product: String) async {
        guard let url = DealFinderLink.searchURL(for: product) else { return }
        isLoading = true
        defer { isLoading = false }
        do {
            let scraped = try await Self.scrape(url: url)
            let plz = (UserDefaults.standard.string(forKey: DealFinderLink.plzKey) ?? "").filter(\.isNumber)
            offers = scraped
            lastFetched = Date()
            lastFetchedPLZ = plz
            lastError = nil
            if let blob = try? JSONEncoder().encode(CachedOffers(offers: scraped, fetchedAt: lastFetched!, plz: plz)) {
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

        let plz = (UserDefaults.standard.string(forKey: DealFinderLink.plzKey) ?? "")
            .filter(\.isNumber)
        if !plz.isEmpty {
            await Self.setLocation(plz: plz, in: webView)
        }

        // `.valid` alone matches the FIRST element with that class in document order, which is the
        // <dt class="valid">Gültig:</dt> LABEL, not the <dd class="valid">07.09. - 12.09.</dd> with
        // the actual date range (verified live: `<dl class="dates"><dt class="valid">Gültig:</dt>
        // <dd class="valid">07.09. - 12.09.</dd></dl>`) — every offer's `valid` field silently read
        // "Gültig:" with no date at all, which `DealOffer.init` correctly failed to parse into
        // validFrom/validTo, which `isCurrentlyActive` then correctly treated as "can't confirm,
        // exclude" — so EVERY offer vanished once that filter shipped. `dd.valid` picks the actual date.
        let js = """
        Array.from(document.querySelectorAll('li.offer-list-item')).map(li => ({
            store: li.querySelector('.retailer-name a')?.textContent?.trim() ?? '',
            price: li.querySelector('.price .price')?.textContent?.trim() ?? '',
            valid: li.querySelector('dd.valid')?.textContent?.trim() ?? '',
            info: li.querySelector('.info')?.textContent?.trim() ?? ''
        }))
        """
        guard let raw = try await webView.evaluateJavaScript(js) as? [[String: String]] else { return [] }
        return raw.compactMap(DealOffer.init).filter(\.isCurrentlyActive)
            .sorted { ($0.price ?? .infinity) < ($1.price ?? .infinity) }
    }

    /// Drives marktguru's own location picker (the header's "Ort ändern" control) via injected JS,
    /// rather than hand-building the `mg_user-settings` cookie: the cookie's actual shape embeds
    /// server-assigned fields (a location id, lat/lon, timestamps) that only marktguru's own
    /// location-search returns — verified live that writing a partial cookie ourselves degrades the
    /// page (location shows "undefined", fewer offers render), so letting the site's own code pick
    /// the first autocomplete match and write its own cookie is the only path that renders cleanly.
    /// Best-effort: if the page markup doesn't match, offers still load for whatever region the
    /// existing cookie (or none) already implies.
    private static func setLocation(plz: String, in webView: WKWebView) async {
        _ = try? await webView.evaluateJavaScript("document.querySelector('.location-pin')?.click();")
        try? await Task.sleep(nanoseconds: 300_000_000)
        _ = try? await webView.evaluateJavaScript("""
        (() => {
            const input = document.querySelector('input[placeholder="Suche Postleitzahl oder Ort"]');
            if (!input) return false;
            const setter = Object.getOwnPropertyDescriptor(window.HTMLInputElement.prototype, 'value').set;
            setter.call(input, '\(plz)');
            input.dispatchEvent(new Event('input', { bubbles: true }));
            return true;
        })();
        """)
        // The suggestion list is populated by the site's own async lookup — poll briefly instead of
        // guessing a fixed delay.
        for _ in 0..<8 {
            try? await Task.sleep(nanoseconds: 300_000_000)
            let clicked = (try? await webView.evaluateJavaScript("""
            (() => {
                const option = document.querySelector('li.autocomplete__option');
                if (!option) return false;
                option.click();
                return true;
            })();
            """)) as? Bool ?? false
            if clicked { break }
        }
        // Let the site's own state update + cookie write land before the offer read below.
        try? await Task.sleep(nanoseconds: 500_000_000)
    }

    private struct CachedOffers: Codable { let offers: [DealOffer]; let fetchedAt: Date; let plz: String }
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

    /// Whether `Date()` currently falls inside the offer's validity window. An offer whose "Gültig:"
    /// text didn't parse (validFrom/validTo nil) is treated as NOT active — we can't confirm it's
    /// current, so it's excluded rather than shown on a guess. `validTo` parses to midnight of its
    /// day (no time-of-day in the source text), so the window is checked through the END of that day
    /// — otherwise an offer would read as expired for most of its own last valid day.
    var isCurrentlyActive: Bool {
        guard let from = validFrom, let to = validTo,
              let toEndOfDay = Calendar.current.date(byAdding: .day, value: 1, to: to) else { return false }
        let now = Date()
        return from <= now && now < toEndOfDay
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
