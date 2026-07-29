import Foundation

/// One currency: the ISO 4217 code shown next to the amount and the long label used as a card badge.
struct CurrencyDef: Equatable, Sendable {
    let code: String  // "EUR"
    let name: String  // "Euro"
}

/// An exchange-rate snapshot: every rate quoted as units of that currency per 1 `base`. Downloaded and persisted by `CurrencyRateStore` and handed to `CalcEngine.evaluate` — the engine never fetches, which is what keeps `Core/Calculator/` Foundation-only and pure.
struct CurrencyRates: Codable, Equatable, Sendable {
    let base: String
    let rates: [String: Double]
    /// When this table was downloaded — drives staleness, and doubles as the memo key in `CalcMemo`.
    let fetchedAt: Date

    func rate(for code: String) -> Double? {
        if let rate = rates[code], rate > 0, rate.isFinite { return rate }
        return code == base ? 1 : nil
    }

    /// Cross-rate through the base currency.
    func convert(_ amount: Double, from: String, to: String) -> Double? {
        guard let source = rate(for: from), let target = rate(for: to) else { return nil }
        let output = amount / source * target
        return output.isFinite ? output : nil
    }
}

/// Whether the calculator may answer currency questions at all, and with what.
///
/// `.off` is the shipped default and the *only* state that exists without explicit user consent:
/// the currency path never engages, so a currency query falls through to no card — not an error
/// explaining a feature the user never turned on. `.on(nil)` means consent was given but no
/// snapshot has landed yet, which is the state that earns the "rates unavailable" message.
enum CurrencySource: Equatable, Sendable {
    case off
    /// - Parameters:
    ///   - rates: The snapshot, or nil when consent was given but no table has landed yet.
    ///   - defaultTarget: ISO code of the currency `300 usd` converts *to* when the user names no
    ///     target. Resolved by `CurrencyRateStore` from an explicit override or the macOS locale,
    ///     so the engine itself stays free of any system lookup.
    case on(CurrencyRates?, defaultTarget: String)
}

enum CalcCurrency {
    enum ConversionParse: Equatable {
        case value(input: Double, from: CurrencyDef, to: CurrencyDef, output: Double, rateUnit: String?)
        /// One side is a currency, the other a measurement unit — `10 usd to kg`.
        case mismatch(from: String, to: String)
        /// Both sides are currencies but the snapshot doesn't quote one of them.
        case noRate(code: String)
        /// No snapshot has ever been downloaded (first run, still offline).
        case unavailable
    }

    /// The category label used in the mismatch message, mirroring `UnitCategory.displayName`.
    static let categoryName = "Currency"

    /// Detects `expr currency (to|in|->) currency`, mirroring `CalcUnits.parseConversion`'s shape so both read the same. Runs *after* the unit path, so a query both sides of which are compatible units (`10 pounds to kg`) never reaches here. A missing amount defaults to 1, so `eur to usd` reads as `1 eur to usd`.
    static func parseConversion(_ inputTokens: [CalcToken], source: CurrencySource) -> ConversionParse? {
        guard case .on(let rates, let defaultTarget) = source else { return nil }
        if inputTokens.count == 2,
            case .ident(let from) = inputTokens[0], byName[from] != nil,
            case .ident(let to) = inputTokens[1], byName[to] != nil
        {
            return parseConversion([.number(1), .ident(from), .ident("to"), .ident(to)], source: source)
        }

        // Numeric no-connector pair: `300 usd rub` → 300 USD → RUB. (Two bare codes are already an
        // implied-1 conversion above; a leading amount means an explicit quantity, not "1 of each".)
        if inputTokens.count == 3,
            case .number = inputTokens[0],
            case .ident(let from) = inputTokens[1], byName[from] != nil,
            case .ident(let to) = inputTokens[2], byName[to] != nil
        {
            return parseConversion(
                [inputTokens[0], .ident(from), .ident("to"), .ident(to)], source: source)
        }

        // Single-source form: `300 usd` → 300 USD → the injected default target. Resolves through the
        // same connector path so shorthand, mismatch and no-rate semantics are reused verbatim.
        // When the default target lands on the source currency itself, fall back to EUR — or USD if
        // the source is already EUR — so the conversion stays meaningful, mirroring `CurrencyRateStore`.
        if inputTokens.count == 2,
            case .number = inputTokens[0],
            case .ident(let from) = inputTokens[1], CalcUnits.byName[from] == nil,
            let fromDef = byName[from]
        {
            let targetCode: String?
            if defaultTarget.uppercased() == fromDef.code {
                targetCode = fromDef.code == "EUR" ? "USD" : "EUR"
            } else {
                targetCode = defaultTarget
            }
            guard let to = targetCode.flatMap({ byName[$0.lowercased()] }) else { return nil }
            return parseConversion(
                [inputTokens[0], .ident(from), .ident("to"), .ident(to.code.lowercased())],
                source: source)
        }

        var tokens = amountFirst(inputTokens)
        var rateUnit: String?

        // `USD1K in GBP`, `$5K to EUR`, and `10K in GBP` (bare shorthand defaults to USD).
        if case .ident(let shorthand) = tokens.first,
            let expanded = expandPrefixedShorthand(shorthand)
        {
            tokens.replaceSubrange(0...0, with: [.number(expanded.amount), .ident(expanded.code)])
        } else if tokens.count >= 3, case .number(let amount) = tokens[0],
            case .ident(let code) = tokens[1], byName[code] != nil,
            case .ident(let suffix) = tokens[2], let multiplier = shorthandMultiplier(suffix)
        {
            tokens.replaceSubrange(0...2, with: [.number(amount * multiplier), .ident(code)])
        } else if tokens.count >= 2, case .number(let amount) = tokens[0],
            case .ident(let suffix) = tokens[1], let multiplier = shorthandMultiplier(suffix)
        {
            tokens.replaceSubrange(0...1, with: [.number(amount * multiplier), .ident("usd")])
        }

        // Preserve a simple per-time denominator: `8 dollars/hour in gbp`.
        if tokens.count >= 6, case .op("/") = tokens[tokens.count - 4],
            case .ident(let unit) = tokens[tokens.count - 3]
        {
            rateUnit = canonicalRateUnit(unit)
            guard rateUnit != nil else { return nil }
            tokens.removeSubrange((tokens.count - 4)..<(tokens.count - 2))
        }

        tokens = amountFirst(tokens)
        guard tokens.count >= 3, CalcUnits.isConnector(tokens[tokens.count - 2]),
            case .ident(let toName) = tokens[tokens.count - 1],
            case .ident(let fromName) = tokens[tokens.count - 3]
        else { return nil }

        switch (byName[fromName], byName[toName]) {
        case (nil, nil):
            return nil
        case (.some, nil):
            guard let to = CalcUnits.byName[toName] else { return nil }
            return .mismatch(from: categoryName, to: to.category.displayName)
        case (nil, .some):
            guard let from = CalcUnits.byName[fromName] else { return nil }
            return .mismatch(from: from.category.displayName, to: categoryName)
        case (let from?, let to?):
            let valueTokens = Array(tokens[0..<(tokens.count - 3)])
            let input: Double
            if valueTokens.isEmpty {
                input = 1
            } else if let value = CalcParser.evaluate(valueTokens) {
                input = value
            } else {
                return nil
            }

            guard let rates else { return .unavailable }
            guard rates.rate(for: from.code) != nil else { return .noRate(code: from.code) }
            guard rates.rate(for: to.code) != nil else { return .noRate(code: to.code) }
            guard let output = rates.convert(input, from: from.code, to: to.code) else {
                return .noRate(code: to.code)
            }
            return .value(
                input: input, from: from, to: to, output: output, rateUnit: rateUnit)
        }
    }

    private static func expandPrefixedShorthand(_ text: String) -> (amount: Double, code: String)? {
        guard text.count >= 5 else { return nil }
        let code = String(text.prefix(3))
        guard byName[code] != nil, let multiplier = shorthandMultiplier(String(text.suffix(1))) else {
            return nil
        }
        let number = String(text.dropFirst(3).dropLast())
        guard let amount = Double(number) else { return nil }
        return (amount * multiplier, code)
    }

    private static func shorthandMultiplier(_ suffix: String) -> Double? {
        switch suffix {
        case "k": return 1_000
        case "m": return 1_000_000
        case "b": return 1_000_000_000
        default: return nil
        }
    }

    private static func canonicalRateUnit(_ unit: String) -> String? {
        switch unit {
        case "h", "hr", "hrs", "hour", "hours": return "hour"
        case "d", "day", "days": return "day"
        default: return nil
        }
    }

    /// Money is written sign-first (`€20`), so a leading currency ident followed by its amount is swapped back into the `amount currency …` order every parser here expects.
    private static func amountFirst(_ tokens: [CalcToken]) -> [CalcToken] {
        guard tokens.count >= 2, case .ident(let name) = tokens[0], byName[name] != nil,
            case .number = tokens[1]
        else { return tokens }
        var reordered = tokens
        reordered.swapAt(0, 1)
        return reordered
    }

    /// The only currency data still written by hand: nouns several currencies share, where CLDR
    /// correctly refuses to choose ("US dollars", "Canadian dollars" — never a bare "dollars") and
    /// the calculator has to. The count is how many of the feed's currencies claim that word.
    /// Everything unambiguous — names, signs, and 129 uncontested nouns — is generated.
    /// `pound`/`pounds` deliberately overlaps `CalcUnits`' weight; the pipeline order resolves it.
    /// Curated popular assets only. Coinbase exposes hundreds of tickers; accepting all would make
    /// ordinary launcher searches and fiat/unit aliases ambiguous.
    static let crypto: [(code: String, name: String, aliases: [String])] = [
        ("BTC", "Bitcoin", ["bitcoin"]),
        ("ETH", "Ethereum", ["ethereum", "ether"]),
        ("SOL", "Solana", ["solana"]),
        ("POL", "Polygon", ["polygon"]),
        ("TON", "Toncoin", ["toncoin"]),
        ("BNB", "BNB", ["binancecoin"]),
        ("XRP", "XRP", ["ripple"]),
        ("ADA", "Cardano", ["cardano"]),
        ("DOGE", "Dogecoin", ["dogecoin"]),
        ("AVAX", "Avalanche", ["avalanche"]),
        ("LINK", "Chainlink", ["chainlink"]),
        ("DOT", "Polkadot", ["polkadot"]),
        ("LTC", "Litecoin", ["litecoin"]),
        ("BCH", "Bitcoin Cash", ["bitcoincash"]),
        ("SHIB", "Shiba Inu", ["shibainu"]),
    ]

    static let cryptoCodes = Set(crypto.map(\.code))

    private static let contested: [String: [String]] = [
        "USD": ["dollar", "dollars"],  // 22 claimants
        "CHF": ["franc", "francs"],  // 10
        "GBP": ["pound", "pounds"],  // 9
        "MXN": ["peso", "pesos"],  // 8
        "INR": ["rupee", "rupees"],  // 6
        "KES": ["shilling", "shillings"],  // 4
        "AED": ["dirham", "dirhams"],  // 2
        "KRW": ["won"],  // 2
        "RON": ["leu", "lei"],  // 2
        "RUB": ["ruble", "rubles"],  // 2
        "SAR": ["riyal", "riyals"],  // 2
    ]

    /// Lookup by lowercased ident. Codes, display names and uncontested nouns come from
    /// `CurrencyData.generated.swift`; `contested` above is applied last so its choices win.
    static let byName: [String: CurrencyDef] = {
        var defs: [String: CurrencyDef] = [:]
        var table: [String: CurrencyDef] = [:]
        defs.reserveCapacity(CurrencyData.all.count + crypto.count)
        table.reserveCapacity(CurrencyData.all.count + CurrencyData.aliases.count + crypto.count * 2)
        for entry in CurrencyData.all {
            let def = CurrencyDef(code: entry.code, name: entry.name)
            defs[entry.code] = def
            table[entry.code.lowercased()] = def
        }
        for (word, code) in CurrencyData.aliases { table[word] = defs[code] }
        // Crypto ticker codes win over fiat nouns when they collide (`SOL` vs Peruvian "sol").
        // Fiat remains available by ISO code (`PEN`) and its other generated names.
        for asset in crypto {
            let def = CurrencyDef(code: asset.code, name: asset.name)
            defs[asset.code] = def
            table[asset.code.lowercased()] = def
            for alias in asset.aliases { table[alias] = def }
        }
        for (code, words) in contested {
            guard let def = defs[code] else { continue }
            for word in words { table[word] = def }
        }
        return table
    }()
}
