// Standalone test for the calculator engine — compiles the *real* Foundation-only engine sources (no copy to sync): swiftc Tinycast/Core/Calculator/*.swift Tools/calc-test.swift -o /tmp/calc-test && /tmp/calc-test

import Foundation

@main
@MainActor
struct CalcTests {
    static var failures = 0
    static var passes = 0

    static func main() {
        // Arithmetic & precedence
        expectDisplay("2+2", "4")
        expectDisplay("5*7", "35")
        expectDisplay("100/4", "25")
        expectDisplay("2^10", "1,024")
        expectDisplay("2^3^2", "512")  // right-associative
        expectDisplay("(5+2)*3", "21")
        expectDisplay("5!", "120")
        expectDisplay("3!!", "720")  // (3!)! — chained postfix
        expectDisplay("-5+3", "-2")
        expectDisplay("-2^2", "-4")  // unary minus binds looser than ^
        expectDisplay("10/4", "2.5")
        expectDisplay("1/3", "0.3333333333")
        expectDisplay("2.5 * 4", "10")
        expectDisplay("1,000 + 234", "1,234")  // grouping commas accepted in input

        // Functions
        expectDisplay("sqrt(64)", "8")
        expectDisplay("sqrt 64", "8")
        expectDisplay("sqrt 64 + 36", "44")  // bare arg is one operand: sqrt(64) + 36
        expectDisplay("log(1000)", "3")
        expectDisplay("ln(e)", "1")
        expectDisplay("sin(30deg)", "0.5")
        expectDisplay("cos(60deg)", "0.5")
        expectDisplay("tan(45deg)", "1")
        expectDisplay("sin(pi/2)", "1")
        expectDisplay("abs(-4)", "4")
        expectDisplay("floor(2.7)", "2")
        expectDisplay("ceil(2.1)", "3")
        expectDisplay("round(2.5)", "3")
        expectDisplay("SQRT(64)", "8")  // case-insensitive

        // Constants
        expectDisplay("2*pi", "6.283185307")
        expectDisplay("π*2", "6.283185307")
        expectDisplay("e^2", "7.389056099")

        // Percent
        expectDisplay("20% of 450", "90")
        expectDisplay("450 + 20%", "540")
        expectDisplay("450 - 15%", "382.5")
        expectDisplay("20%", "0.2")

        // Unit conversion — length / weight / temperature / time / area / volume / storage
        expectDisplay("10km to mi", "6.213711922 mi")
        expectDisplay("10 km in miles", "6.213711922 mi")
        expectDisplay("5ft in cm", "152.4 cm")
        expectDisplay("1 m to ft", "3.280839895 ft")
        expectDisplay("10 cm in in", "3.937007874 in")
        expectDisplay("10 in in cm", "25.4 cm")  // first "in" is the unit, second the connector
        expectDisplay("16 oz to lb", "1 lb")
        expectDisplay("2.2 lbs to kg", "0.997903214 kg")
        expectDisplay("100 C to F", "212 °F")
        expectDisplay("32F to C", "0 °C")
        expectDisplay("273.15K to C", "0 °C")
        expectDisplay("0 F to C", "-17.77777778 °C")
        expectDisplay("300 K to C", "26.85 °C")
        expectDisplay("90min to hr", "1.5 hr")
        expectDisplay("2hr to min", "120 min")
        expectDisplay("1day to sec", "86,400 s")
        expectDisplay("1 week to hr", "168 hr")
        expectDisplay("2 acre to m2", "8,093.712845 m²")
        expectDisplay("1 m² to ft²", "10.76391042 ft²")
        expectDisplay("2L -> mL", "2,000 mL")
        expectDisplay("1 cup to tbsp", "16 tbsp")
        expectDisplay("1 gal to L", "3.785411784 L")
        expectDisplay("1 GiB to MB", "1,073.741824 MB")
        expectDisplay("1 GB to MiB", "953.6743164 MiB")
        expectDisplay("8 bit to byte", "1 B")
        expectDisplay("2*5 km to mi", "6.213711922 mi")  // expression on the left side

        // Design PPI conversion — physical length ↔ pixels with an explicit `at <n> ppi` suffix
        expectDisplay("2 inches in px at 72 ppi", "144 px")
        expectBadges("2 inches in px at 72 ppi", source: "Inches", target: "Pixels")
        expectDisplay("1 cm in px at 72 ppi", "28.34645669 px")
        expectDisplay("5 cm to px at 300 ppi", "590.5511811 px")
        expectDisplay("10 mm in px at 96 ppi", "37.79527559 px")
        expectExpression("2 inches in px at 72 ppi", "2 in")
        // Reverse: pixels → physical length when PPI is supplied
        expectDisplay("216 px to in at 72 ppi", "3 in")
        expectBadges("216 px to in at 72 ppi", source: "Pixels", target: "Inches")
        expectDisplay("144 px to cm at 72 ppi", "5.08 cm")
        // Expression on the value side
        expectDisplay("2*3 inches in px at 72 ppi", "432 px")
        // Implied quantity of 1
        expectDisplay("inch to px at 72 ppi", "72 px")
        // Malformed / missing / nonpositive PPI falls through to no card (not an error)
        expectNil("2 inches in px")          // missing `at … ppi`
        expectNil("2 inches in px at 72")     // missing trailing `ppi`
        expectNil("2 inches in px at ppi")     // missing PPI value
        expectNil("2 inches in px at 0 ppi")   // nonpositive PPI
        expectNil("2 inches in px at -72 ppi")
        expectNil("2 kg in px at 72 ppi")        // non-length source → not a PPI query
        // The duration targets are NOT stolen by the generic unit converters — checked at the parser
        // level so this stays valid once the date slice turns the full query into a timespan/workday card.
        if let t = CalcTokenizer.tokenize("145 mins to timespan"),
            CalcUnits.parseConversion(t) != nil || CalcUnits.parseUnitPairConversion(t) != nil
        {
            fail("145 mins to timespan", expected: "unit parser nil", got: "matched")
        } else { passes += 1 }
        if let t = CalcTokenizer.tokenize("55h in workdays"),
            CalcUnits.parseConversion(t) != nil
                || CalcUnits.parseUnitPairConversion(t) != nil
                || CalcUnits.parseBareConversion(t) != nil
        {
            fail("55h in workdays", expected: "unit parser nil", got: "matched")
        } else { passes += 1 }

        // Number bases
        expectDisplay("255 to hex", "0xFF")
        expectDisplay("255 to binary", "0b11111111")
        expectDisplay("0xff to decimal", "255")
        expectDisplay("0b1010 to decimal", "10")
        expectDisplay("255 to octal", "0o377")
        expectDisplay("0xff", "255")  // bare radix literal echoes decimal

        // Friendly category errors
        expectError("10kg to sec", "Cannot convert Weight to Time.")
        expectError("100 mL to km", "Cannot convert Volume to Length.")
        expectError("1 GB to hr", "Cannot convert Digital Storage to Time.")

        // Non-calculator input → no card
        expectNil("safari")
        expectNil("1password")
        expectNil("45")
        expectNil("3.14")
        expectNil("pi")
        expectNil("e")
        expectNil("10km to")  // half-typed conversion
        expectNil("10 to mi")
        expectNil("45+")  // half-typed expression
        expectNil("sqrt()")
        expectNil("2.5!")  // factorial needs an integer
        expectNil("")

        // Formatting: display grouped, copyText plain
        expectDisplay("1234567*1", "1,234,567")
        expectCopy("1234567*1", "1234567")
        expectCopy("10km to mi", "6.213711922 mi")
        expectDisplay("-1234.5-0.25", "-1,234.75")

        // Card expression echo
        expectExpression("3*3", "3×3")
        expectExpression("10km to mi", "10 km")

        // Badges on explicit conversions
        expectBadges("10km to mi", source: "Kilometers", target: "Miles")
        expectBadges("100 C to F", source: "Celsius", target: "Fahrenheit")

        // Bare-unit auto-conversion (no connector)
        expectDisplay("1m", "3 feet 3.37007874 inches")
        expectExpression("1m", "1 m")
        expectBadges("1m", source: "Meters", target: "Feet")
        expectDisplay("1hr", "60 min")
        expectBadges("1hr", source: "Hours", target: "Minutes")
        expectDisplay("5ft", "1.524 m")
        expectDisplay("100g", "3.527396195 oz")
        expectDisplay("2*3 kg", "13.22773573 lb")  // value side is a full expression
        expectDisplay("20 celsius", "68 °F")
        expectDisplay("50cm", "19.68503937 in")
        // Ambiguous single-letter aliases stay app searches, not bare temperatures
        expectNil("5k")
        expectNil("100 c")
        expectNil("32f")

        // Date/time — evaluated against a fixed clock: Fri 2026-07-24 00:18 UTC
        expectDisplayAt("hrs till 9am", "8.7 hours")
        expectBadgesAt("hrs till 9am", source: "12:18 AM", target: "9:00 AM")
        expectDisplayAt("hrs till july", "8,207.7 hours")
        expectBadgesAt("hrs till july", source: "12:18 AM", target: "12:00 AM")
        expectDisplayAt("days till 9april", "259 days")
        expectBadgesAt(
            "days till 9april", source: "Friday, 24 July", target: "Friday, 9 April, 2027")
        expectDisplayAt("days till july", "342 days")
        expectBadgesAt(
            "days till july", source: "Friday, 24 July", target: "Thursday, 1 July, 2027")
        expectDisplayAt("days until tomorrow", "1 day")
        expectDisplayAt("weeks till 9april", "37 weeks")  // 259 / 7
        expectDisplayAt("today + 3 weeks", "Friday, 14 August")
        expectDisplayAt("now + 90 min", "Friday, 24 July at 1:48 AM")
        expectDisplayAt("jul 4 - today", "345 days")
        expectBadgesAt("jul 4 - today", source: "Sunday, 4 July, 2027", target: "Friday, 24 July")
        // Arithmetic with spaced operators must still be plain math, not date math
        expectDisplayAt("10 - 3", "7")
        expectDisplayAt("450 + 20%", "540")
        // Letter-free `m/d - m/d` is fraction math, not a date difference (both operands are valid arithmetic)
        expectDisplayAt("5/2 - 1/2", "2")
        expectDisplayAt("3/4 - 1/4", "0.5")
        expectDisplayAt("1/2 - 1/4", "0.25")
        // A slash date still reads as a date when the other side names a keyword
        expectDisplayAt("9/4 - today", "42 days")
        expectDisplayAt("today - 9/4", "-42 days")
        // Bare date/unit words alone are app searches, not cards
        expectNilAt("today")
        expectNilAt("july")
        expectNilAt("tomorrow")

        // New relative date/duration grammars
        expectDisplayAt("monday in 3 weeks", "Monday, 17 August")
        expectBadgesAt("monday in 3 weeks", source: "Monday, 27 July", target: "Result")
        
        expectDisplayAt("35 days ago", "Friday, 19 June")
        expectBadgesAt("35 days ago", source: "Friday, 24 July", target: "Result")
        
        expectDisplayAt("days until 31 Mar", "250 days")
        expectBadgesAt("days until 31 Mar", source: "Friday, 24 July", target: "Wednesday, 31 March, 2027")
        
        expectDisplayAt("August 5 + 5", "Monday, 10 August")
        expectBadgesAt("August 5 + 5", source: "Wednesday, 5 August", target: "Result")
        
        expectDisplayAt("3:45pm + 5", "Friday, 24 July at 8:45 PM")
        expectBadgesAt("3:45pm + 5", source: "Friday, 24 July at 3:45 PM", target: "Result")
        
        expectDisplayAt("time in 4 hours", "Friday, 24 July at 4:18 AM")
        expectBadgesAt("time in 4 hours", source: "Now", target: "Result")
        
        expectDisplayAt("145 mins to timespan", "2h 25m")
        expectBadgesAt("145 mins to timespan", source: "Duration", target: "Timespan")
        
        expectDisplayAt("55h in workdays", "6.875 workdays")
        expectBadgesAt("55h in workdays", source: "55 Hours", target: "Workdays")
        
        expectDisplayAt("workhours in 2023", "2,080 hours")
        expectBadgesAt("workhours in 2023", source: "2023", target: "Work Hours")
        
        expectDisplayAt("2024-03-15T14:30:00Z", "Friday, 15 March, 2024 at 2:30 PM")
        expectBadgesAt("2024-03-15T14:30:00Z", source: "ISO 8601", target: "Result")

        // Angle units (deg is a real unit now, not just a trig postfix)
        expectDisplay("1 deg", "0.01745329252 rad")
        expectExpression("1 deg", "1 deg")
        expectBadges("1 deg", source: "Degrees", target: "Radians")
        expectDisplay("90 deg to rad", "1.570796327 rad")
        expectDisplay("1 rad to deg", "57.29577951 deg")
        expectDisplay("1 turn to deg", "360 deg")
        expectDisplay("200 grad to deg", "180 deg")
        expectDisplay("sin(30deg)", "0.5")  // trig postfix still works inside parens

        // Implied quantity of 1 for number-less conversions
        expectDisplay("day to s", "86,400 s")
        expectDisplay("deg to rad", "0.01745329252 rad")
        expectDisplay("m to ft", "3.280839895 ft")

        // `unit unit` shorthand → 1 of the first in the second
        expectDisplay("day s", "86,400 s")
        expectBadges("day s", source: "Days", target: "Seconds")
        expectDisplay("days s", "86,400 s")
        expectDisplay("hr min", "60 min")
        expectNil("m s")  // different categories → no card, no error

        // Extra unit categories: speed / pressure / data rate
        expectDisplay("100 kmh to mph", "62.13711922 mph")
        expectDisplay("60 mph to kmh", "96.56064 km/h")
        expectDisplay("100 mbps to kbps", "100,000 Kbps")
        expectBadges("100 kmh to mph", source: "Kilometers per Hour", target: "Miles per Hour")

        // Percentage phrasings
        expectDisplay("20% off 500", "400")
        expectDisplay("50 as % of 200", "25%")

        // Natural-language math grammar (manual: "square root of 625" / "2 power 10")
        expectDisplay("square root of 625", "25")
        expectDisplay("square root of 2", "1.414213562")
        expectDisplay("2 power 10", "1,024")
        expectDisplay("3 power 4", "81")
        expectDisplay("2 power 3 power 2", "512")  // right-associative like `^`

        // Advanced trig: cot/csc/sec + hyperbolic + inverse (incl. acos)
        expectDisplay("cot(45deg)", "1")
        expectDisplay("csc(30deg)", "2")
        expectDisplay("sec(60deg)", "2")
        expectDisplay("sinh(1)", "1.175201194")
        expectDisplay("cosh(0)", "1")
        expectDisplay("tanh(0)", "0")
        expectDisplay("asin(1)", "1.570796327")
        expectDisplay("acos(0.5)", "1.047197551")
        expectDisplay("atan(1)", "0.7853981634")
        expectDisplay("asinh(0)", "0")

        // Finance: tip, ratio, compound growth
        expectDisplay("15% tip on 42", "48.3")
        expectDisplay("ratio of 3 to 5", "0.6")
        expectDisplay("ratio of 1 to 4", "0.25")
        expectDisplay("1000 invested at 7% after 3 years", "1,225.043")
        expectDisplay("invested at 7% after 3 years", "1.225043")
        expectDisplay("500 invested at 5% after 10 years", "814.4473134")

        // Badges on paths that previously had none
        expectBadges("255 to hex", source: "Decimal", target: "Hexadecimal")
        expectBadges("0xff to decimal", source: "Hexadecimal", target: "Decimal")
        expectBadges("3*3", source: "Expression", target: "Result")
        expectBadges("20% off 500", source: "Expression", target: "Result")

        // days since — past elapsed, against the fixed clock (Fri 2026-07-24)
        expectDisplayAt("days since 9jul", "15 days")
        expectBadgesAt("days since 9jul", source: "Thursday, 9 July", target: "Friday, 24 July")
        expectDisplayAt("weeks since 3jul", "3 weeks")
        expectDisplayAt("days since yesterday", "1 day")
        // Date ± duration now carries the resolved start as a source badge
        expectBadgesAt("today + 3 weeks", source: "Friday, 24 July", target: "Result")

        // Currency — against the fixed `fx` table below (1 USD = 0.92 EUR = 0.79 GBP = 157 JPY)
        expectDisplay("1 euro to dollars", "1.09 USD")
        expectExpression("1 euro to dollars", "1 EUR")
        expectBadges("1 euro to dollars", source: "Euro", target: "US Dollar")
        expectDisplay("50 GBP in euros", "58.23 EUR")
        expectDisplay("100 dollars to yen", "15,700.00 JPY")
        expectDisplay("100 usd -> eur", "92.00 EUR")
        expectDisplay("2*50 usd to eur", "92.00 EUR")  // expression on the value side
        expectDisplay("eur to usd", "1.09 USD")  // implied amount of 1
        expectCopy("100 dollars to yen", "15700.00 JPY")
        // Currency signs, prefixed and suffixed
        expectDisplay("€20 to GBP", "17.17 GBP")
        expectDisplay("20€ to GBP", "17.17 GBP")
        expectDisplay("£50 in dollars", "63.29 USD")
        expectDisplay("$100 to yen", "15,700.00 JPY")
        // Sub-cent cross-rates widen instead of collapsing to 0.00
        expectDisplay("1 jpy to usd", "0.006369 USD")
        // …and stay in plain notation past 1e-5, where "%g" would flip to "5.539e-05"
        expectDisplay("1 idr to usd", "0.00005539 USD")
        expectCopy("1 idr to usd", "0.00005539 USD")
        // Currency never steals a query the unit table can answer
        expectDisplay("10 pounds to kilograms", "4.5359237 kg")
        expectDisplay("10 pounds", "4.5359237 kg")
        expectDisplay("10 pounds to euros", "11.65 EUR")
        expectBadges("10 pounds to euros", source: "British Pound", target: "Euro")
        // Currency ↔ unit is a friendly category error, like Weight ↔ Time
        expectError("10 usd to kg", "Cannot convert Currency to Weight.")
        expectError("10 kg to usd", "Cannot convert Weight to Currency.")
        // A known currency the snapshot doesn't quote, and no snapshot at all
        expectError("5 usd to npr", "No exchange rate for NPR.")
        expectErrorWithoutRates(
            "1 eur to usd", "Exchange rates unavailable — check your connection.")
        expectNil("10 usd to nonsense")
        expectNil("usd")  // a lone code is still an app search
        expectNil("btc")  // crypto isn't in the table — Frankfurter is central-bank fiat only
        // The table is generated from the feed's own currency list, so codes nobody hand-typed still
        // resolve — reaching "no rate" (not "no card") is what proves recognition.
        expectError("5 usd to zmw", "No exchange rate for ZMW.")
        expectError("5 usd to afn", "No exchange rate for AFN.")
        check(
            "CurrencyData sizes", expected: "true",
            got:
                "\(CurrencyData.all.count >= 120 && CurrencyData.signs.count >= 20 && CurrencyData.aliases.count >= 100)"
        )
        // Badges come from CLDR's label, which is shorter than the registry name where it matters
        expectBadges("1 chf to usd", source: "Swiss Franc", target: "US Dollar")
        expectBadges("1 aed to usd", source: "UAE Dirham", target: "US Dollar")
        // Nouns only one currency claims are generated — nobody hand-typed these
        expectError("1 zloty to usd", "No exchange rate for PLN.")
        expectError("1 forint to usd", "No exchange rate for HUF.")
        expectError("1 taka to usd", "No exchange rate for BDT.")
        expectError("1 rand to usd", "No exchange rate for ZAR.")
        expectDisplay("1 euro to dollars", "1.09 USD")
        // Accented nouns resolve with or without the accent
        expectError("1 krónur to usd", "No exchange rate for ISK.")
        expectError("1 kronur to usd", "No exchange rate for ISK.")
        // Nouns several currencies share are the hand-written part, and they must still win
        expectDisplay("100 dollars to yen", "15,700.00 JPY")
        expectDisplay("10 pounds to euros", "11.65 EUR")
        expectDisplay("1 franc to usd", "1.23 USD")
        expectError("1 peso to usd", "No exchange rate for MXN.")
        // `krona` is contested (SEK vs ISK) and deliberately assigned to neither
        expectNil("1 krona to usd")
        // Slang is no longer carried: CLDR has no "quid", and we don't hand-maintain synonyms
        expectNil("50 quid to usd")
        expectNil("100 bucks to eur")
        // The last word of a name isn't always its noun — "Special Drawing Rights" is not a "rights"
        expectNil("1 rights to usd")
        // A result too small to show at all reads as a clean zero, never "-0.00"
        expectDisplay("-0.0000000000001 usd to eur", "0.00 EUR")
        expectDisplay("0 usd to eur", "0.00 EUR")
        expectDisplay("-5 usd to eur", "-4.60 EUR")
        // CUP (Cuban peso) is a generated code that collides with a unit; volume still wins
        expectDisplay("1 cup to ml", "236.5882365 mL")
        expectDisplay("1 cup to tbsp", "16 tbsp")

        // Consent gate: without it the currency path doesn't exist. Not an error card explaining a
        // feature the user never enabled — no card at all, so the query falls through to app search.
        expectNilWithoutConsent("1 euro to dollars")
        expectNilWithoutConsent("100 dollars to yen")
        expectNilWithoutConsent("50 GBP in euros")
        expectNilWithoutConsent("eur to usd")
        expectNilWithoutConsent("€20 to GBP")
        expectNilWithoutConsent("2*50 usd to cad")
        expectNilWithoutConsent("1 zloty to eur")
        // Even the friendly category error stays silent — it would leak that currency exists.
        expectNilWithoutConsent("10 usd to kg")
        expectNilWithoutConsent("10 kg to usd")
        // Everything that isn't currency is untouched by the gate.
        expectDisplayWithoutConsent("10 pounds to kilograms", "4.5359237 kg")
        expectDisplayWithoutConsent("10 pounds", "4.5359237 kg")
        expectDisplayWithoutConsent("1 cup to ml", "236.5882365 mL")
        expectDisplayWithoutConsent("10km to mi", "6.213711922 mi")
        expectDisplayWithoutConsent("2+2", "4")
        expectDisplayWithoutConsent("255 to hex", "0xFF")
        expectDisplayWithoutConsent("20% off 500", "400")

        // MARK: - Timezone queries
        expectDisplayAt("time in tokyo", "09:18") // 00:18 UTC -> +9 = 09:18
        expectBadgesAt("time in tokyo", source: "UTC", target: "Tokyo")
        expectDisplayAt("5pm ldn in sf", "09:00") // 17:00 UTC+1 -> -7 = 09:00 (Note: London in July is BST (+1), SF is PDT (-7), wait, does test clock inject tz?)
        expectBadgesAt("5pm ldn in sf", source: "London", target: "Los Angeles")
        expectDisplayAt("time diff Paris", "+2 hours") // UTC to CEST (+2)
        expectBadgesAt("time diff Paris", source: "UTC", target: "Paris")
        expectDisplayAt("diff Paris", "+2 hours")
        expectDisplayAt("time in 4 hours in San Francisco", "21:18") // 00:18 UTC + 4h = 04:18 UTC -> PDT (-7) = 21:18 previous day
        expectDisplayAt("time in São Paulo", "21:18") // UTC-3
        expectDisplayAt("time in JFK", "20:18") // UTC-4 EDT
        expectDisplayAt("Time in Dubai", "04:18") // UTC+4

        // MARK: - Currency Parity Cases (CurrencyCryptoParity)
        expectDisplay("USD1K to eur", "920.00 EUR")
        expectDisplay("10K in gbp", "7,900.00 GBP")
        expectDisplay("$5K to eur", "4,600.00 EUR")
        expectDisplay("usd eur", "0.92 EUR")
        expectDisplay("usd rub", "80.00 RUB")
        expectDisplay("sol gbp", "39.50 GBP")
        expectDisplay("8 dollars/hour in gbp", "6.32 GBP/hour")
        expectDisplay("5 btc in gbp", "250,000.00 GBP")
        expectError("5 eth to gbp", "No exchange rate for ETH.")
        expectDisplay("5 sol in gbp", "197.50 GBP")
        expectDisplay("10 pol in eur", "18.40 EUR")
        expectDisplay("2 ton in usd", "5.00 USD")
        expectDisplay("1 solana to usd", "50.00 USD")
        expectBadges("1 toncoin to usd", source: "Toncoin", target: "US Dollar")
        expectError("1 doge to usd", "No exchange rate for DOGE.")
        print("\n\(passes) passed, \(failures) failed")
        exit(failures == 0 ? 0 : 1)
    }

    // MARK: - Fixed clock for deterministic date/time tests (Fri 2026-07-24 00:18:00 UTC)

    static let clock: (now: Date, calendar: Calendar) = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        calendar.locale = Locale(identifier: "en_US")
        var components = DateComponents()
        components.year = 2026
        components.month = 7
        components.day = 24
        components.hour = 0
        components.minute = 18
        components.second = 0
        return (calendar.date(from: components)!, calendar)
    }()

    // MARK: - Fixed exchange rates so currency answers are deterministic

    /// NPR, ZMW and AFN are deliberately absent: the table recognizes them (they're in the generated
    /// list), so a query for one must reach "no exchange rate" rather than falling through to no card.
    static let fx = CurrencyRates(
        base: "USD",
        rates: [
            "USD": 1, "EUR": 0.92, "GBP": 0.79, "JPY": 157, "INR": 83.5, "CAD": 1.36,
            "KRW": 1330, "IDR": 18053, "CHF": 0.81, "AED": 3.6725, "RUB": 80,
            "BTC": 0.0000158, "SOL": 0.02, "POL": 0.5, "TON": 0.4,
        ],
        fetchedAt: Date(timeIntervalSince1970: 1_785_000_000))

    // MARK: - Helpers

    static func expectDisplayAt(_ query: String, _ expected: String) {
        guard
            case .value(let display, _)? = CalcEngine.evaluate(
                query, now: clock.now, calendar: clock.calendar)?.payload
        else {
            fail(query, expected: expected, got: "nil / error")
            return
        }
        check(query, expected: expected, got: display)
    }

    static func expectBadgesAt(_ query: String, source: String, target: String) {
        guard let result = CalcEngine.evaluate(query, now: clock.now, calendar: clock.calendar)
        else {
            fail(query, expected: "\(source) → \(target)", got: "nil")
            return
        }
        check(query + " [source badge]", expected: source, got: result.sourceBadge ?? "nil")
        check(query + " [target badge]", expected: target, got: result.targetBadge ?? "nil")
    }

    static func expectNilAt(_ query: String) {
        if let result = CalcEngine.evaluate(query, now: clock.now, calendar: clock.calendar) {
            fail(query, expected: "nil", got: "\(result.payload)")
        } else {
            passes += 1
        }
    }

    static func expectBadges(_ query: String, source: String, target: String) {
        guard let result = CalcEngine.evaluate(query, currency: .on(fx)) else {
            fail(query, expected: "\(source) → \(target)", got: "nil")
            return
        }
        check(query + " [source badge]", expected: source, got: result.sourceBadge ?? "nil")
        check(query + " [target badge]", expected: target, got: result.targetBadge ?? "nil")
    }

    static func expectDisplay(_ query: String, _ expected: String) {
        guard case .value(let display, _)? = CalcEngine.evaluate(query, currency: .on(fx))?.payload
        else {
            fail(query, expected: expected, got: "nil / error")
            return
        }
        check(query, expected: expected, got: display)
    }

    static func expectCopy(_ query: String, _ expected: String) {
        guard case .value(_, let copy)? = CalcEngine.evaluate(query, currency: .on(fx))?.payload
        else {
            fail(query, expected: expected, got: "nil / error")
            return
        }
        check(query, expected: expected, got: copy)
    }

    static func expectError(_ query: String, _ expected: String) {
        guard case .error(let message)? = CalcEngine.evaluate(query, currency: .on(fx))?.payload
        else {
            fail(query, expected: "error: \(expected)", got: "nil / value")
            return
        }
        check(query, expected: expected, got: message)
    }

    /// Consented, but no snapshot has landed yet — first run, or still offline.
    static func expectErrorWithoutRates(_ query: String, _ expected: String) {
        guard case .error(let message)? = CalcEngine.evaluate(query, currency: .on(nil))?.payload
        else {
            fail(query, expected: "error: \(expected)", got: "nil / value")
            return
        }
        check(query, expected: expected, got: message)
    }

    /// No consent: the currency path must not engage. Checks the explicit `.off` source and the
    /// default argument, since a caller that forgets to pass one must still get the feature off.
    static func expectNilWithoutConsent(_ query: String) {
        if let result = CalcEngine.evaluate(query, currency: .off) {
            fail(query, expected: "nil (consent withheld)", got: "\(result.payload)")
        } else if let result = CalcEngine.evaluate(query) {
            fail(query, expected: "nil (default source)", got: "\(result.payload)")
        } else {
            passes += 1
        }
    }

    /// A non-currency answer that must survive with the feature switched off.
    static func expectDisplayWithoutConsent(_ query: String, _ expected: String) {
        guard case .value(let display, _)? = CalcEngine.evaluate(query, currency: .off)?.payload
        else {
            fail(query, expected: expected, got: "nil / error")
            return
        }
        check(query, expected: expected, got: display)
    }

    static func expectExpression(_ query: String, _ expected: String) {
        guard let result = CalcEngine.evaluate(query, currency: .on(fx)) else {
            fail(query, expected: expected, got: "nil")
            return
        }
        check(query, expected: expected, got: result.expression)
    }

    static func expectNil(_ query: String) {
        if let result = CalcEngine.evaluate(query, currency: .on(fx)) {
            fail(query, expected: "nil", got: "\(result.payload)")
        } else {
            passes += 1
        }
    }

    static func check(_ query: String, expected: String, got: String) {
        if got == expected {
            passes += 1
        } else {
            fail(query, expected: expected, got: got)
        }
    }

    static func fail(_ query: String, expected: String, got: String) {
        failures += 1
        print("FAIL  \(query)\n      expected: \(expected)\n      got:      \(got)")
    }
}
