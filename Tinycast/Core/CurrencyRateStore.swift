import Foundation

/// Downloads, caches and periodically refreshes the exchange-rate table the calculator's currency
/// conversions run on. Network and disk live here, never in `Core/Calculator/`: the engine is handed
/// a finished `CurrencySource`, which is what keeps it Foundation-only and pure.
///
/// This reaches the network, so it is gated on explicit consent — off until the user enables currency
/// conversion in Settings. Every path that could reach the network or surface a rate re-checks
/// `isEnabled` rather than trusting a caller.
@MainActor
final class CurrencyRateStore: ObservableObject {
    /// Frankfurter (`frankfurter.dev`) — open-source, no key, no account, no quota, rates blended from
    /// 84 central banks. Unfiltered: `CurrencyData.generated.swift` is generated from this same feed's
    /// currency list, so every quote it returns is one the calculator can answer for (~1.4 KB gzipped).
    static let provider = "Frankfurter"
    static let providerURL = URL(string: "https://frankfurter.dev")!
    private nonisolated static let endpoint = URL(
        string: "https://api.frankfurter.dev/v2/rates?base=USD")!
    private nonisolated static let cryptoEndpoint = URL(
        string: "https://api.coinbase.com/v2/exchange-rates?currency=USD")!
    /// Daily. The feed republishes about once a day, so asking more often just costs requests without
    /// getting newer numbers — and the age is measured from the persisted snapshot, so relaunching
    /// Tinycast repeatedly doesn't re-fetch.
    static let refreshInterval: TimeInterval = 24 * 3600
    /// Shorter retry so a machine that was offline at launch picks rates up soon after it reconnects.
    private static let retryInterval: TimeInterval = 15 * 60

    /// Explicit user consent, persisted under the bundle-scoped defaults. Deliberately *not* part of
    /// `AppSettings`: `SettingsBackup` mirrors that type field-for-field, and an imported config —
    /// or a Raycast import — must never be able to silently grant network access.
    @Published private(set) var isEnabled: Bool

    /// The newest snapshot, or nil when none has landed — and always nil while consent is withheld.
    @Published private(set) var rates: CurrencyRates?

    /// The currency `300 usd` converts to when no target is named. Store-owned like consent (not
    /// `AppSettings`), so a backup/Raycast import can't smuggle a preferred currency in. `nil` means
    /// "use the system default" — resolved at read time so a locale change takes effect immediately.
    @Published private(set) var defaultCurrencyOverride: String?

    private static let consentKey = "currencyRatesEnabled"
    private static let defaultCurrencyKey = "currencyDefaultTarget"
    private let defaults = UserDefaults.standard
    private let fileURL: URL
    private var pump: Task<Void, Never>?

    init() {
        // Absent reads as false, which is the only safe default for a network feature.
        isEnabled = defaults.bool(forKey: Self.consentKey)
        let bundleID = Bundle.main.bundleIdentifier ?? "com.tinycast.app"
        let base = FileManager.default
            .urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent(bundleID, isDirectory: true)
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        fileURL = base.appendingPathComponent("currency-rates.json")

        // Guard 1 — a disabled feature doesn't even read back a snapshot left on disk.
        guard isEnabled, let data = try? Data(contentsOf: fileURL) else {
            defaultCurrencyOverride = defaults.string(forKey: Self.defaultCurrencyKey)
            return
        }
        rates = try? JSONDecoder().decode(CurrencyRates.self, from: data)
        defaultCurrencyOverride = defaults.string(forKey: Self.defaultCurrencyKey)
    }

    /// What the calculator is allowed to use. Guard 2 — the read path: without consent the engine is
    /// handed `.off`, so a currency query produces no card rather than an error about missing rates.
    var source: CurrencySource {
        isEnabled ? .on(rates, defaultTarget: effectiveDefaultCurrency) : .off
    }

    /// The resolved target `300 usd` converts to: the explicit override when set, else the macOS
    /// locale's currency. Falls back to EUR only when the locale names no currency at all — a stable
    /// default, never a per-query guess. (The case where the resolved target equals the query's actual
    /// source is handled in `CalcCurrency`, which knows the source; the store can't, and shouldn't.)
    var effectiveDefaultCurrency: String {
        if let override = defaultCurrencyOverride, !override.isEmpty {
            return override
        }
        if let code = Locale.current.currency?.identifier {
            return code
        }
        return "EUR"
    }

    /// Every fiat currency the calculator can quote, sorted by long name for the Settings picker.
    /// Crypto is excluded: it isn't a sensible implicit/conversion *target* for a bare `300 usd`.
    let supportedCurrencies: [CurrencyDef] = {
        CurrencyData.all
            .map { CurrencyDef(code: $0.code, name: $0.name) }
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }()

    /// The Settings picker's setter. Empty/nil clears the override so the locale default takes over.
    func setDefaultCurrency(_ code: String?) {
        let normalized = (code ?? "").uppercased()
        let value = normalized.isEmpty ? nil : normalized
        guard value != defaultCurrencyOverride else { return }
        defaultCurrencyOverride = value
        defaults.set(value, forKey: Self.defaultCurrencyKey)
    }

    /// Starts the refresh loop: fetch whenever the cached snapshot is older than `refreshInterval`,
    /// otherwise sleep exactly until it expires. A failed fetch keeps the stale snapshot and retries
    /// sooner. Guard 3 — no consent, no loop, so `AppCore.start()` can call this unconditionally.
    func start() {
        guard isEnabled else { return }
        // Replace rather than bail on a live pump: a loop that has already exited still leaves a
        // non-nil task behind, and a `pump == nil` guard would let that dead task block every restart.
        pump?.cancel()
        pump = Task { [weak self] in
            while !Task.isCancelled, let self, self.isEnabled {
                // Clamped: a snapshot stamped in the future (clock skew, an edited cache file) must
                // not park the loop for longer than one interval.
                let age = max(0, self.rates.map { Date().timeIntervalSince($0.fetchedAt) } ?? .infinity)
                guard age >= Self.refreshInterval else {
                    try? await Task.sleep(for: .seconds(Self.refreshInterval - age))
                    continue
                }
                let ok = await self.fetchAndStore()
                try? await Task.sleep(for: .seconds(ok ? Self.refreshInterval : Self.retryInterval))
            }
        }
    }

    /// The Settings toggle's only entry point, called after the user accepts the consent dialog.
    /// Disabling tears the loop down, drops the snapshot and deletes the cached file — opting out
    /// shouldn't leave downloaded data behind.
    func setEnabled(_ enabled: Bool) {
        guard enabled != isEnabled else { return }
        isEnabled = enabled
        defaults.set(enabled, forKey: Self.consentKey)
        if enabled {
            start()
        } else {
            pump?.cancel()
            pump = nil
            rates = nil
            try? FileManager.default.removeItem(at: fileURL)
        }
    }

    /// Manual "Update Now" from Settings. Returns whether a fresh table landed, so the pane can say
    /// the fetch failed instead of leaving the button to spring back with nothing changed.
    func refreshNow() async -> Bool {
        guard isEnabled else { return false }
        return await fetchAndStore()
    }

    private func fetchAndStore() async -> Bool {
        // Guard 4 — re-checked at the network boundary itself: the pump may have been sleeping when
        // the user revoked consent, and this is the last line before a request goes out.
        guard isEnabled, let fetched = try? await Self.fetch() else { return false }
        // Re-check after the await: consent can be withdrawn while the request is in flight, and a
        // late response must not resurrect the feature or write the cache back to disk.
        guard isEnabled else { return false }
        rates = fetched
        if let data = try? JSONEncoder().encode(fetched) {
            try? data.write(to: fileURL, options: .atomic)
        }
        return true
    }

    /// Deliberately not `URLSession.shared`: the provider serves the table `Cache-Control: public,
    /// max-age=…`, so the shared session would write a second copy into the on-disk `URLCache` that
    /// `setEnabled(false)` never deletes. Cacheless, so revoking consent really does leave nothing behind.
    private nonisolated static let session: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        config.urlCache = nil
        return URLSession(configuration: config)
    }()

    /// Off-main by way of `URLSession`'s async API; the decoded table is a plain value, so nothing but `CurrencyRates` crosses back.
    private nonisolated static func fetch() async throws -> CurrencyRates {
        async let fiatTask = session.data(for: URLRequest(url: endpoint, timeoutInterval: 20))
        async let cryptoTask = session.data(for: URLRequest(url: cryptoEndpoint, timeoutInterval: 20))
        
        let (data, response) = try await fiatTask
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            throw URLError(.badServerResponse)
        }

        let rows = try JSONDecoder().decode([RateRow].self, from: data)
        guard let base = rows.first?.base else { throw URLError(.cannotParseResponse) }
        var rates: [String: Double] = [:]
        rates.reserveCapacity(rows.count + CalcCurrency.cryptoCodes.count + 1)
        for row in rows where row.rate > 0 && row.rate.isFinite && row.base == base {
            rates[row.quote] = row.rate
        }
        guard !rates.isEmpty else { throw URLError(.cannotParseResponse) }
        rates[base] = 1
        
        if let (cData, cRes) = try? await cryptoTask,
            let cHttp = cRes as? HTTPURLResponse, cHttp.statusCode == 200,
            let json = try? JSONDecoder().decode(CoinbaseResponse.self, from: cData)
        {
            for code in CalcCurrency.cryptoCodes {
                if let text = json.data.rates[code], let rate = Double(text), rate > 0, rate.isFinite {
                    rates[code] = rate
                }
            }
        }

        return CurrencyRates(base: base, rates: rates, fetchedAt: Date())
    }

    private struct CoinbaseResponse: Decodable {
        struct Payload: Decodable {
            let rates: [String: String]
        }
        let data: Payload
    }

    private struct RateRow: Decodable {
        let base: String
        let quote: String
        let rate: Double
    }
}
