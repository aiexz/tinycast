import Foundation

/// Natural-language percentage phrasings the arithmetic parser doesn't cover: `20% off 500` (a discount) and `50 as % of 200` (a ratio). Foundation-only so `Tools/calc-test.swift` compiles it with the rest of the engine. `X% of Y` and `Y + X%` already fall out of the `of`/percent operators, so they aren't handled here.
enum CalcPercent {
    static func evaluate(_ tokens: [CalcToken], query: String) -> CalcResult? {
        parseOff(tokens, query: query)
            ?? parseTipOn(tokens, query: query)
            ?? parseRatioOf(tokens, query: query)
            ?? parseCompoundGrowth(tokens, query: query)
            ?? parseAsPercentOf(tokens, query: query)
    }

    /// `<pct>% off <value>` → the value reduced by pct percent (`20% off 500` → 400).
    private static func parseOff(_ tokens: [CalcToken], query: String) -> CalcResult? {
        guard let off = tokens.firstIndex(of: .ident("off")), off >= 2,
            tokens[off - 1] == .op("%"),
            let pct = CalcParser.evaluate(Array(tokens[0..<(off - 1)])),
            let base = CalcParser.evaluate(Array(tokens[(off + 1)...]))
        else { return nil }
        let result = base * (1 - pct / 100)
        guard result.isFinite else { return nil }
        return card(query, CalcFormatter.display(result), CalcFormatter.copyText(result))
    }

    /// `<x> as % of <y>` → x / y × 100, rendered as a percentage (`50 as % of 200` → 25%).
    private static func parseAsPercentOf(_ tokens: [CalcToken], query: String) -> CalcResult? {
        guard let asIdx = tokens.firstIndex(of: .ident("as")), asIdx + 2 < tokens.count,
            tokens[asIdx + 1] == .op("%"), tokens[asIdx + 2] == .ident("of"),
            let x = CalcParser.evaluate(Array(tokens[0..<asIdx])),
            let y = CalcParser.evaluate(Array(tokens[(asIdx + 3)...])), y != 0
        else { return nil }
        let ratio = x / y * 100
        guard ratio.isFinite else { return nil }
        return card(query, "\(CalcFormatter.display(ratio))%", "\(CalcFormatter.copyText(ratio))%")
    }

    /// `<pct>% tip on <value>` → the bill plus that tip (`15% tip on 42` → 48.3), mirroring how `off` returns the resulting amount.
    private static func parseTipOn(_ tokens: [CalcToken], query: String) -> CalcResult? {
        guard let on = tokens.firstIndex(of: .ident("on")), on >= 3, on + 1 < tokens.count,
            tokens[on - 1] == .ident("tip"), tokens[on - 2] == .op("%"),
            let pct = CalcParser.evaluate(Array(tokens[0..<(on - 2)])),
            let base = CalcParser.evaluate(Array(tokens[(on + 1)...]))
        else { return nil }
        let result = base * (1 + pct / 100)
        guard result.isFinite else { return nil }
        return card(query, CalcFormatter.display(result), CalcFormatter.copyText(result))
    }

    /// `ratio of <x> to <y>` → x / y, a dimensionless ratio (`ratio of 3 to 5` → 0.6).
    private static func parseRatioOf(_ tokens: [CalcToken], query: String) -> CalcResult? {
        guard let of = tokens.firstIndex(of: .ident("of")), of >= 1, of + 2 < tokens.count,
            tokens[0] == .ident("ratio"),
            let to = tokens.lastIndex(of: .ident("to")), to > of
        else { return nil }
        guard let x = CalcParser.evaluate(Array(tokens[(of + 1)..<to])),
            let y = CalcParser.evaluate(Array(tokens[(to + 1)...])), y != 0
        else { return nil }
        let result = x / y
        guard result.isFinite else { return nil }
        return card(query, CalcFormatter.display(result), CalcFormatter.copyText(result))
    }
    /// `[<principal>] invested at <rate>% after <years>[ years]` → principal compounded at rate over years (`1000 invested at 7% after 3 years` → 1225.043). Without a principal, $1 is assumed, so `invested at 7% after 3 years` yields the growth factor (1.225043).
    private static func parseCompoundGrowth(_ tokens: [CalcToken], query: String) -> CalcResult? {
        guard let invested = tokens.firstIndex(of: .ident("invested")),
            let at = tokens.firstIndex(where: { $0 == .ident("at") }), at > invested,
            let after = tokens.firstIndex(of: .ident("after")), after > at,
            after >= at + 2, tokens[at + 2] == .op("%"),
            let rate = CalcParser.evaluate(Array(tokens[(at + 1)..<(at + 2)]))
        else { return nil }
        // Year tokens run from after+1 to end; an optional trailing ident "years" marker is dropped.
        var yearTokens = Array(tokens[(after + 1)..<tokens.count])
        if yearTokens.last == .ident("years") { yearTokens.removeLast() }
        guard let years = CalcParser.evaluate(yearTokens), years >= 0 else { return nil }
        let factor = pow(1 + rate / 100, years)
        guard factor.isFinite, factor > 0 else { return nil }
        let principal: Double = invested == 0
            ? 1
            : (CalcParser.evaluate(Array(tokens[0..<invested])) ?? 0)
        guard principal.isFinite else { return nil }
        let result = principal * factor
        guard result.isFinite else { return nil }
        return card(query, CalcFormatter.display(result), CalcFormatter.copyText(result))
    }


    private static func card(_ query: String, _ display: String, _ copy: String) -> CalcResult {
        CalcResult(
            expression: query.split(whereSeparator: \.isWhitespace).joined(separator: " "),
            sourceBadge: "Expression",
            targetBadge: "Result",
            payload: .value(display: display, copyText: copy))
    }
}
