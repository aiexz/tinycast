import Foundation

/// Natural-language date/time calculations for the launcher card, kept Foundation-only so `Tools/calc-test.swift` compiles it standalone. `now`/`calendar` are injected so the tests can assert exact strings against a fixed clock. Four grammars:
///   A. duration until a moment — `hrs till 9am`, `days till 9april`
///   B. duration since a past moment — `days since 9jul`, `hrs since noon`
///   C. a moment ± a duration — `today + 3 weeks`, `now + 90 min`
///   D. difference between two moments — `jul 4 - today`
enum CalcDateTime {
    /// Which occurrence of a bare, recurring date/time a phrase resolves to: the upcoming one (`till`) or the most recent past one (`since`). Absolute dates ignore it.
    private enum MomentBias { case future, past }

    static func evaluate(_ raw: String, now: Date = Date(), calendar: Calendar = .current)
        -> CalcResult? {
        let echo = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        let query = echo.lowercased()
        guard !query.isEmpty else { return nil }

        // Newer non-arith grammars run before the hasArith gate so unspaced ISO / `in` phrases match. Each recognizer is fully self-validating and returns nil unless its whole shape is present, so unit/currency/search queries fall through to the tokenizer path untouched.

        // `35 days ago` — <n> <unit> ago.
        if let result = parseAgo(query, echo: echo, now: now, calendar: calendar) {
            return result
        }
        // `monday in 3 weeks`, `time in 4 hours`, `workhours in 2023`, `55h in workdays` — ` in ` relative forms that aren't unit conversions; returns nil for a trailing ` in <place>` so the timezone branch wins.
        if let result = parseRelative(query, echo: echo, now: now, calendar: calendar) {
            return result
        }
        // ISO Zulu
        if let result = parseISOZulu(query, echo: echo, now: now, calendar: calendar) {
            return result
        }
        // `145 mins to timespan` — a duration flattened to a human timespan; `timespan` is not a unit, so the unit converter returns nil and we win here.
        if let result = parseTimespan(query, echo: echo, now: now, calendar: calendar) {
            return result
        }

        // TimezoneParity owns this slot: a `parseTimezone(query, echo:echo, now:now, calendar:calendar)` branch for ` in <place>` / `time diff` forms. Insert here — after parseRelative yields nil for place-suffixed queries.
        if let result = parseTimezone(query, echo: echo, now: now, calendar: calendar) {
            return result
        }

        // Cheap gate: the A–D grammars always carry a connector, so app searches skip all the parsing.
        let hasUntil =
            query.contains(" till ") || query.contains(" until ") || query.contains(" til ")
        let hasSince = query.contains(" since ")
        let hasArith = query.contains(" + ") || query.contains(" - ")
        guard hasUntil || hasSince || hasArith else { return nil }

        if hasUntil, let result = parseUntil(query, echo: echo, now: now, calendar: calendar) {
            return result
        }
        if hasSince, let result = parseSince(query, echo: echo, now: now, calendar: calendar) {
            return result
        }
        if hasArith, let result = parseArithmetic(query, echo: echo, now: now, calendar: calendar) {
            return result
        }
        return nil
    }

    // MARK: - Grammar A: duration until a moment

    private static func parseUntil(_ query: String, echo: String, now: Date, calendar: Calendar)
        -> CalcResult? {
        guard let connector = [" until ", " till ", " til "].first(where: query.contains) else {
            return nil
        }
        let parts = query.components(separatedBy: connector)
        guard parts.count == 2,
            let unit = durationUnit(parts[0]),
            let moment = parseMoment(parts[1], now: now, calendar: calendar)
        else { return nil }

        let reference = unit.subDay ? now : calendar.startOfDay(for: now)
        let target = unit.subDay ? moment.date : calendar.startOfDay(for: moment.date)

        let value: Double
        switch unit.kind {
        case .day:
            value = Double(calendar.dateComponents([.day], from: reference, to: target).day ?? 0)
        case .week:
            let days = calendar.dateComponents([.day], from: reference, to: target).day ?? 0
            value = Double(days) / 7
        case .subSecond:
            value = target.timeIntervalSince(reference) / unit.seconds
        }

        let word = value == 1 ? unit.singular : unit.plural
        let source =
            unit.subDay
            ? timeString(now, calendar: calendar)
            : dateString(reference, now: now, calendar: calendar)
        let targetBadge =
            unit.subDay
            ? timeString(moment.date, calendar: calendar)
            : dateString(target, now: now, calendar: calendar)

        return CalcResult(
            expression: echo,
            sourceBadge: source,
            targetBadge: targetBadge,
            payload: .value(
                display: "\(CalcFormatter.display(value)) \(word)",
                copyText: "\(CalcFormatter.copyText(value)) \(word)"))
    }

    // MARK: - Grammar B: duration since a past moment

    private static func parseSince(_ query: String, echo: String, now: Date, calendar: Calendar)
        -> CalcResult? {
        let parts = query.components(separatedBy: " since ")
        guard parts.count == 2,
            let unit = durationUnit(parts[0]),
            let moment = parseMoment(parts[1], now: now, calendar: calendar, bias: .past)
        else { return nil }

        let reference = unit.subDay ? now : calendar.startOfDay(for: now)
        let past = unit.subDay ? moment.date : calendar.startOfDay(for: moment.date)

        let value: Double
        switch unit.kind {
        case .day:
            value = Double(calendar.dateComponents([.day], from: past, to: reference).day ?? 0)
        case .week:
            let days = calendar.dateComponents([.day], from: past, to: reference).day ?? 0
            value = Double(days) / 7
        case .subSecond:
            value = reference.timeIntervalSince(past) / unit.seconds
        }

        let word = value == 1 ? unit.singular : unit.plural
        let source =
            unit.subDay
            ? timeString(past, calendar: calendar)
            : dateString(past, now: now, calendar: calendar)
        let targetBadge =
            unit.subDay
            ? timeString(now, calendar: calendar)
            : dateString(reference, now: now, calendar: calendar)

        return CalcResult(
            expression: echo,
            sourceBadge: source,
            targetBadge: targetBadge,
            payload: .value(
                display: "\(CalcFormatter.display(value)) \(word)",
                copyText: "\(CalcFormatter.copyText(value)) \(word)"))
    }

    // MARK: - Grammars C & D: moment ± duration / moment − moment

    private static func parseArithmetic(
        _ query: String, echo: String, now: Date, calendar: Calendar
    ) -> CalcResult? {
        // Split on the earliest space-surrounded operator; unspaced dashes (ISO dates, times) stay intact.
        let plus = query.range(of: " + ")
        let minus = query.range(of: " - ")
        let (opRange, op): (Range<String.Index>, Character)
        switch (plus, minus) {
        case (let p?, let m?): (opRange, op) = p.lowerBound < m.lowerBound ? (p, "+") : (m, "-")
        case (let p?, nil): (opRange, op) = (p, "+")
        case (nil, let m?): (opRange, op) = (m, "-")
        default: return nil
        }

        let left = String(query[..<opRange.lowerBound])
        let right = String(query[opRange.upperBound...])
        guard let base = parseMoment(left, now: now, calendar: calendar) else { return nil }

        // C: moment ± duration → a new moment.
        if let duration = parseDurationPhrase(right) {
            // Negating Int.min traps; degrade to no card on that edge.
            guard op == "+" || duration.count != .min else { return nil }
            let signed = op == "-" ? -duration.count : duration.count
            guard
                let result = calendar.date(
                    byAdding: duration.component, value: signed, to: base.date)
            else { return nil }
            let hasTime = base.hasTime || duration.subDay
            let display = momentString(result, hasTime: hasTime, now: now, calendar: calendar)
            let sourceBadge = momentString(
                base.date, hasTime: base.hasTime, now: now, calendar: calendar)
            return CalcResult(
                expression: echo, sourceBadge: sourceBadge, targetBadge: "Result",
                payload: .value(display: display, copyText: display))
        }

        // C (bare number): a moment + a lone integer adds in the unit that matches the base — days for a date (`August 5 + 5`), hours for a clock time (`3:45pm + 5`). A real date/time phrase always carries a letter, so letter-free operands (`10 + 5`, `5/2 + 1`) defer to plain arithmetic.
        if op == "+",
            (left.contains(where: \.isLetter) || right.contains(where: \.isLetter)),
            let count = Int(right)
        {
            let component: Calendar.Component = base.hasTime ? .hour : .day
            guard
                let result = calendar.date(byAdding: component, value: count, to: base.date)
            else { return nil }
            let hasTime = base.hasTime
            let display = momentString(result, hasTime: hasTime, now: now, calendar: calendar)
            let sourceBadge = momentString(
                base.date, hasTime: base.hasTime, now: now, calendar: calendar)
            return CalcResult(
                expression: echo, sourceBadge: sourceBadge, targetBadge: "Result",
                payload: .value(display: display, copyText: display))
        }

        // D: moment − moment → a whole-day difference. A real date subtraction always names a month/weekday/keyword; two letter-free operands (`5/2 - 1/2`) are equally valid as arithmetic, so defer to the calculator rather than silently reading them as dates.
        guard op == "-",
            left.contains(where: \.isLetter) || right.contains(where: \.isLetter),
            let other = parseMoment(right, now: now, calendar: calendar)
        else {
            return nil
        }
        let days =
            calendar.dateComponents(
                [.day], from: calendar.startOfDay(for: other.date),
                to: calendar.startOfDay(for: base.date)
            ).day ?? 0
        let word = abs(days) == 1 ? "day" : "days"
        return CalcResult(
            expression: echo,
            sourceBadge: dateString(base.date, now: now, calendar: calendar),
            targetBadge: dateString(other.date, now: now, calendar: calendar),
            payload: .value(display: "\(days) \(word)", copyText: "\(days) \(word)"))
    }

    // MARK: - New Duration & Relative queries

    private static func parseAgo(_ query: String, echo: String, now: Date, calendar: Calendar) -> CalcResult? {
        guard query.hasSuffix(" ago") else { return nil }
        let phrase = String(query.dropLast(4)).trimmingCharacters(in: .whitespaces)
        let atoms = atomize(phrase)
        guard atoms.count == 2, let count = Int(atoms[0]), let unit = durationUnit(atoms[1]) else { return nil }

        let base = unit.subDay ? now : calendar.startOfDay(for: now)
        let component: Calendar.Component
        let value: Int
        switch unit.kind {
        case .day: component = .day; value = count
        case .week: component = .day; value = count * 7
        case .subSecond:
            if unit.seconds == 1 { component = .second; value = count }
            else if unit.seconds == 60 { component = .minute; value = count }
            else { component = .hour; value = count }
        }
        guard let result = calendar.date(byAdding: component, value: -value, to: base) else { return nil }
        let display = momentString(result, hasTime: unit.subDay, now: now, calendar: calendar)
        return absoluteMomentCard(echo: echo, display: display, sourceBadge: momentString(base, hasTime: unit.subDay, now: now, calendar: calendar))
    }

    private static func parseRelative(_ query: String, echo: String, now: Date, calendar: Calendar) -> CalcResult? {
        // Exclude timezone queries: if there's a second ` in ` or ` in <place>`, return nil so TimezoneParity handles it.
        let parts = query.components(separatedBy: " in ")
        guard parts.count == 2 else { return nil }
        
        let left = parts[0].trimmingCharacters(in: .whitespaces)
        let right = parts[1].trimmingCharacters(in: .whitespaces)
        
        if left == "workhours", let year = Int(right) {
            return parseWorkhoursInYear(year: year, echo: echo, calendar: calendar)
        }
            if right == "workdays" {
                return parseHoursInWorkdays(left, echo: echo)
            }
            if left == "time" {
                return parseTimeInHours(right, echo: echo, now: now, calendar: calendar)
            }
            if let weekday = weekdayByName[left], let duration = parseDurationPhrase(right), !duration.subDay {
                // e.g. "monday in 3 weeks"
                guard let base = nextWeekday(weekday, offsetToFuture: true, past: false, now: now, calendar: calendar) else { return nil }
                guard let result = calendar.date(byAdding: duration.component, value: duration.count, to: base.date) else { return nil }
                let display = momentString(result, hasTime: false, now: now, calendar: calendar)
                return absoluteMomentCard(echo: echo, display: display, sourceBadge: momentString(base.date, hasTime: false, now: now, calendar: calendar))
            }
        return nil
    }

    private static func parseTimespan(_ query: String, echo: String, now: Date, calendar: Calendar) -> CalcResult? {
        guard query.hasSuffix(" to timespan") else { return nil }
        let phrase = String(query.dropLast(12)).trimmingCharacters(in: .whitespaces)
        let atoms = atomize(phrase)
        guard atoms.count == 2, let count = Double(atoms[0]), let unit = durationUnit(atoms[1]) else { return nil }
        
        let totalSeconds = count * unit.seconds
        let hours = Int(totalSeconds / 3600)
        let minutes = Int((totalSeconds.truncatingRemainder(dividingBy: 3600)) / 60)
        
        var display = ""
        if hours > 0 { display += "\(hours)h " }
        if minutes > 0 || hours == 0 { display += "\(minutes)m" }
        display = display.trimmingCharacters(in: .whitespaces)
        
        return CalcResult(
            expression: echo,
            sourceBadge: "Duration",
            targetBadge: "Timespan",
            payload: .value(display: display, copyText: display))
    }

    private static func parseTimeInHours(_ phrase: String, echo: String, now: Date, calendar: Calendar) -> CalcResult? {
        let atoms = atomize(phrase)
        guard atoms.count == 2, let count = Int(atoms[0]), let unit = durationUnit(atoms[1]), unit.subDay else { return nil }
        let component: Calendar.Component = (unit.seconds == 3600) ? .hour : ((unit.seconds == 60) ? .minute : .second)
        guard let result = calendar.date(byAdding: component, value: count, to: now) else { return nil }
        let display = momentString(result, hasTime: true, now: now, calendar: calendar)
        return absoluteMomentCard(echo: echo, display: display, sourceBadge: "Now")
    }

    private static func parseWorkhoursInYear(year: Int, echo: String, calendar: Calendar) -> CalcResult? {
        guard year > 1900 && year < 2100 else { return nil }
        guard let start = makeDate(year, 1, 1, calendar), let end = makeDate(year + 1, 1, 1, calendar) else { return nil }
        var weekdays = 0
        var d = start
        while d < end {
            let w = calendar.component(.weekday, from: d)
            if w >= 2 && w <= 6 { weekdays += 1 }
            d = calendar.date(byAdding: .day, value: 1, to: d)!
        }
        let hours = weekdays * 8
        let text = "\(CalcFormatter.grouped(String(hours))) hours"
        return CalcResult(
            expression: echo,
            sourceBadge: String(year),
            targetBadge: "Work Hours",
            payload: .value(display: text, copyText: text))
    }

    private static func parseHoursInWorkdays(_ phrase: String, echo: String) -> CalcResult? {
        let atoms = atomize(phrase)
        guard atoms.count == 2, let count = Double(atoms[0]), let unit = durationUnit(atoms[1]), unit.seconds == 3600 else { return nil }
        let days = count / 8.0
        let text = "\(CalcFormatter.display(days)) \(days == 1.0 ? "workday" : "workdays")"
        return CalcResult(
            expression: echo,
            sourceBadge: "\(CalcFormatter.display(count)) \(unit.plural.capitalized)",
            targetBadge: "Workdays",
            payload: .value(display: text, copyText: text))
    }

    private static func parseISOZulu(_ query: String, echo: String, now: Date, calendar: Calendar) -> CalcResult? {
        // Naive split to verify strict ISO Zulu shape, since 8601 formatting is unavailable in core Foundation DateFormatter without iOS 10 fallback gymnastics.
        let parts = query.components(separatedBy: "t")
        guard parts.count == 2, parts[1].hasSuffix("z") else { return nil }
        let datePart = parts[0]
        let timePart = String(parts[1].dropLast())
        let dateAtoms = datePart.split(separator: "-").map(String.init)
        let timeAtoms = timePart.split(separator: ":").map(String.init)
        guard dateAtoms.count == 3, timeAtoms.count >= 2,
              let year = Int(dateAtoms[0]), let month = Int(dateAtoms[1]), let day = Int(dateAtoms[2]),
              let hour = Int(timeAtoms[0]), let minute = Int(timeAtoms[1])
        else { return nil }
        let second = timeAtoms.count == 3 ? (Int(timeAtoms[2]) ?? 0) : 0
        
        var comps = DateComponents()
        comps.year = year; comps.month = month; comps.day = day
        comps.hour = hour; comps.minute = minute; comps.second = second
        // Use UTC calendar to parse the Zulu timestamp faithfully, then display it in the injected calendar's timezone
        var utcCal = Calendar(identifier: .gregorian)
        utcCal.timeZone = TimeZone(identifier: "UTC")!
        guard let utcDate = utcCal.date(from: comps) else { return nil }
        
        let display = momentString(utcDate, hasTime: true, now: now, calendar: calendar)
        return absoluteMomentCard(echo: echo, display: display, sourceBadge: "ISO 8601")
    }

    private static func absoluteMomentCard(echo: String, display: String, sourceBadge: String) -> CalcResult {
        CalcResult(
            expression: echo,
            sourceBadge: sourceBadge,
            targetBadge: "Result",
            payload: .value(display: display, copyText: display))
    }

    // MARK: - Moment parsing

    private struct Moment {
        let date: Date
        /// True when the phrase named a clock time ("9am", "now"); false for a bare date, so callers know whether to show a time badge.
        let hasTime: Bool
    }

    private static func parseMoment(
        _ phrase: String, now: Date, calendar: Calendar, bias: MomentBias = .future
    ) -> Moment? {
        let atoms = atomize(phrase)
        switch atoms.count {
        case 1:
            return parseSingle(atoms[0], now: now, calendar: calendar, bias: bias)
        case 2:
            return parsePair(atoms[0], atoms[1], now: now, calendar: calendar, bias: bias)
        default:
            return nil
        }
    }

    private static func parseSingle(
        _ atom: String, now: Date, calendar: Calendar, bias: MomentBias
    ) -> Moment? {
        let sod = calendar.startOfDay(for: now)
        switch atom {
        case "now": return Moment(date: now, hasTime: true)
        case "today": return Moment(date: sod, hasTime: false)
        case "tomorrow":
            return shift(sod, days: 1, calendar: calendar).map { Moment(date: $0, hasTime: false) }
        case "yesterday":
            return shift(sod, days: -1, calendar: calendar).map { Moment(date: $0, hasTime: false) }
        case "noon": return clockMoment(hour: 12, minute: 0, now: now, calendar: calendar, bias: bias)
        case "midnight":
            return clockMoment(hour: 0, minute: 0, now: now, calendar: calendar, bias: bias)
        default: break
        }
        if let weekday = weekdayByName[atom] {
            return nextWeekday(
                weekday, offsetToFuture: false, past: bias == .past, now: now, calendar: calendar)
        }
        if let month = monthByName[atom] {
            return monthDayMoment(month: month, day: 1, now: now, calendar: calendar, bias: bias)
        }
        return parseDateAtom(atom, now: now, calendar: calendar, bias: bias)
    }

    private static func parsePair(
        _ a: String, _ b: String, now: Date, calendar: Calendar, bias: MomentBias
    ) -> Moment? {
        // number + month  /  month + number  →  a day in that month
        if let month = monthByName[b], let day = Int(a) {
            return monthDayMoment(month: month, day: day, now: now, calendar: calendar, bias: bias)
        }
        if let month = monthByName[a], let day = Int(b) {
            return monthDayMoment(month: month, day: day, now: now, calendar: calendar, bias: bias)
        }
        // clock + am/pm  →  a time today (or tomorrow if it has passed)
        if b == "am" || b == "pm", let (hour, minute) = parseClock(a) {
            guard (1...12).contains(hour) else { return nil }
            let adjusted = b == "pm" ? (hour % 12) + 12 : hour % 12
            return clockMoment(
                hour: adjusted, minute: minute, now: now, calendar: calendar, bias: bias)
        }
        // next / last  +  weekday or month
        if a == "next" || a == "last" {
            if let weekday = weekdayByName[b] {
                return nextWeekday(
                    weekday, offsetToFuture: a == "next", past: a == "last", now: now,
                    calendar: calendar)
            }
            if let month = monthByName[b] {
                return monthDayMoment(
                    month: month, day: 1, now: now, calendar: calendar,
                    bias: a == "last" ? .past : .future)
            }
        }
        return nil
    }

    /// A lone numeric atom that carries its own separators: `14:00`, `2027-04-09`, `9/4`, `9/4/2027`.
    private static func parseDateAtom(
        _ atom: String, now: Date, calendar: Calendar, bias: MomentBias
    ) -> Moment? {
        if atom.contains(":") {
            guard let (hour, minute) = parseClock(atom) else { return nil }
            return clockMoment(hour: hour, minute: minute, now: now, calendar: calendar, bias: bias)
        }
        if atom.contains("-") {
            let parts = atom.split(separator: "-").map(String.init)
            guard parts.count == 3, let year = Int(parts[0]), year > 31,
                let month = Int(parts[1]), let day = Int(parts[2]),
                let date = makeDate(year, month, day, calendar)
            else { return nil }
            return Moment(date: date, hasTime: false)
        }
        if atom.contains("/") {
            let parts = atom.split(separator: "/").map(String.init)
            if parts.count == 2, let month = Int(parts[0]), let day = Int(parts[1]) {
                return monthDayMoment(
                    month: month, day: day, now: now, calendar: calendar, bias: bias)
            }
            if parts.count == 3, let month = Int(parts[0]), let day = Int(parts[1]),
                let year = Int(parts[2]), let date = makeDate(fullYear(year), month, day, calendar) {
                return Moment(date: date, hasTime: false)
            }
        }
        return nil
    }

    // MARK: - Moment builders

    private static func clockMoment(
        hour: Int, minute: Int, now: Date, calendar: Calendar, bias: MomentBias = .future
    ) -> Moment? {
        guard (0...23).contains(hour), (0...59).contains(minute) else { return nil }
        let sod = calendar.startOfDay(for: now)
        guard var date = calendar.date(bySettingHour: hour, minute: minute, second: 0, of: sod)
        else { return nil }
        switch bias {
        case .future:
            if date <= now, let next = shift(date, days: 1, calendar: calendar) { date = next }
        case .past:
            if date > now, let prev = shift(date, days: -1, calendar: calendar) { date = prev }
        }
        return Moment(date: date, hasTime: true)
    }

    /// The given day of `month`: with `.future` bias the upcoming occurrence (this year if still ahead, else next), with `.past` the most recent one (this year if already passed, else last) — matching the "upcoming"/"since" readings of a bare date.
    private static func monthDayMoment(
        month: Int, day: Int, now: Date, calendar: Calendar, bias: MomentBias = .future
    ) -> Moment? {
        let year = calendar.component(.year, from: now)
        guard let thisYear = makeDate(year, month, day, calendar) else { return nil }
        let sod = calendar.startOfDay(for: now)
        switch bias {
        case .future:
            if thisYear >= sod { return Moment(date: thisYear, hasTime: false) }
            guard let nextYear = makeDate(year + 1, month, day, calendar) else { return nil }
            return Moment(date: nextYear, hasTime: false)
        case .past:
            if thisYear <= sod { return Moment(date: thisYear, hasTime: false) }
            guard let lastYear = makeDate(year - 1, month, day, calendar) else { return nil }
            return Moment(date: lastYear, hasTime: false)
        }
    }

    private static func nextWeekday(
        _ weekday: Int, offsetToFuture: Bool, past: Bool = false, now: Date, calendar: Calendar
    ) -> Moment? {
        let sod = calendar.startOfDay(for: now)
        let today = calendar.component(.weekday, from: sod)
        if past {
            var back = (today - weekday + 7) % 7
            if back == 0 { back = 7 }
            return shift(sod, days: -back, calendar: calendar).map {
                Moment(date: $0, hasTime: false)
            }
        }
        var ahead = (weekday - today + 7) % 7
        if ahead == 0 && offsetToFuture { ahead = 7 }
        return shift(sod, days: ahead, calendar: calendar).map { Moment(date: $0, hasTime: false) }
    }

    // MARK: - Durations

    private enum DurKind { case subSecond, day, week }

    private struct DurUnit {
        let seconds: Double
        let singular: String
        let plural: String
        let kind: DurKind
        var subDay: Bool { kind == .subSecond }
    }

    private static func durationUnit(_ phrase: String) -> DurUnit? {
        guard let last = phrase.split(separator: " ").last.map(String.init) else { return nil }
        switch last {
        case "s", "sec", "secs", "second", "seconds":
            return DurUnit(seconds: 1, singular: "second", plural: "seconds", kind: .subSecond)
        case "min", "mins", "minute", "minutes":
            return DurUnit(seconds: 60, singular: "minute", plural: "minutes", kind: .subSecond)
        case "h", "hr", "hrs", "hour", "hours":
            return DurUnit(seconds: 3600, singular: "hour", plural: "hours", kind: .subSecond)
        case "d", "day", "days":
            return DurUnit(seconds: 86400, singular: "day", plural: "days", kind: .day)
        case "wk", "week", "weeks":
            return DurUnit(seconds: 604800, singular: "week", plural: "weeks", kind: .week)
        default:
            return nil
        }
    }

    private struct DurationPhrase {
        let count: Int
        let component: Calendar.Component
        let subDay: Bool
    }

    /// `<n> <unit>` for date arithmetic; weeks fold to days so `date(byAdding:)` stays DST-safe.
    private static func parseDurationPhrase(_ phrase: String) -> DurationPhrase? {
        let atoms = atomize(phrase)
        guard atoms.count == 2, let count = Int(atoms[0]) else { return nil }
        switch atoms[1] {
        case "s", "sec", "secs", "second", "seconds":
            return DurationPhrase(count: count, component: .second, subDay: true)
        case "min", "mins", "minute", "minutes":
            return DurationPhrase(count: count, component: .minute, subDay: true)
        case "h", "hr", "hrs", "hour", "hours":
            return DurationPhrase(count: count, component: .hour, subDay: true)
        case "d", "day", "days":
            return DurationPhrase(count: count, component: .day, subDay: false)
        case "wk", "week", "weeks":
            // Absurd counts overflow the fold to days; degrade to no card rather than trap.
            let (days, overflow) = count.multipliedReportingOverflow(by: 7)
            return overflow ? nil : DurationPhrase(count: days, component: .day, subDay: false)
        default: return nil
        }
    }

    // MARK: - Formatting

    private static func momentString(_ date: Date, hasTime: Bool, now: Date, calendar: Calendar)
        -> String {
        let day = dateString(date, now: now, calendar: calendar)
        return hasTime ? "\(day) at \(timeString(date, calendar: calendar))" : day
    }

    private static func dateString(_ date: Date, now: Date, calendar: Calendar) -> String {
        let sameYear =
            calendar.component(.year, from: date) == calendar.component(.year, from: now)
        return format(
            date, calendar: calendar, pattern: sameYear ? "EEEE, d MMMM" : "EEEE, d MMMM, yyyy")
    }

    private static func timeString(_ date: Date, calendar: Calendar) -> String {
        format(date, calendar: calendar, pattern: "h:mm a")
    }

    private static func format(_ date: Date, calendar: Calendar, pattern: String) -> String {
        let formatter = DateFormatter()
        formatter.calendar = calendar
        formatter.timeZone = calendar.timeZone
        // Follow the injected calendar's locale so weekday/month names match the user's language; the test clock pins en_US for deterministic assertions.
        formatter.locale = calendar.locale ?? Locale(identifier: "en_US")
        formatter.dateFormat = pattern
        return formatter.string(from: date)
    }

    // MARK: - Low-level helpers

    /// Split into letter-runs and number-runs (":", "/", "-", "." stay inside a number-run), so `9april` → ["9","april"] and `2027-04-09` stays whole.
    private static func atomize(_ text: String) -> [String] {
        var atoms: [String] = []
        var current = ""
        var currentIsNumber = false
        func flush() {
            if !current.isEmpty { atoms.append(current) }
            current = ""
        }
        for ch in text {
            if ch == " " {
                flush()
                continue
            }
            let isNumeric = ch.isNumber || ch == ":" || ch == "/" || ch == "-" || ch == "."
            let isLetter = ch.isLetter
            if current.isEmpty {
                current.append(ch)
                currentIsNumber = isNumeric && !isLetter
            } else if isLetter && currentIsNumber {
                flush()
                current.append(ch)
                currentIsNumber = false
            } else if isNumeric && !isLetter && !currentIsNumber {
                flush()
                current.append(ch)
                currentIsNumber = true
            } else {
                current.append(ch)
            }
        }
        flush()
        return atoms
    }

    private static func parseClock(_ atom: String) -> (hour: Int, minute: Int)? {
        if atom.contains(":") {
            let parts = atom.split(separator: ":").map(String.init)
            guard parts.count == 2, let hour = Int(parts[0]), let minute = Int(parts[1]) else {
                return nil
            }
            return (hour, minute)
        }
        guard let hour = Int(atom) else { return nil }
        return (hour, 0)
    }

    private static func makeDate(_ year: Int, _ month: Int, _ day: Int, _ calendar: Calendar)
        -> Date? {
        guard (1...12).contains(month), (1...31).contains(day) else { return nil }
        var components = DateComponents()
        components.year = year
        components.month = month
        components.day = day
        guard let date = calendar.date(from: components),
            calendar.component(.day, from: date) == day,
            calendar.component(.month, from: date) == month
        else { return nil }
        return date
    }

    private static func shift(_ date: Date, days: Int, calendar: Calendar) -> Date? {
        calendar.date(byAdding: .day, value: days, to: date)
    }

    /// Expand a 2-digit year the way most date pickers do (00–68 → 2000s, 69–99 → 1900s); 4-digit years pass through.
    private static func fullYear(_ year: Int) -> Int {
        if year >= 100 { return year }
        return year <= 68 ? 2000 + year : 1900 + year
    }

    private static let monthByName: [String: Int] = [
        "january": 1, "jan": 1, "february": 2, "feb": 2, "march": 3, "mar": 3, "april": 4,
        "apr": 4, "may": 5, "june": 6, "jun": 6, "july": 7, "jul": 7, "august": 8, "aug": 8,
        "september": 9, "sep": 9, "sept": 9, "october": 10, "oct": 10, "november": 11, "nov": 11,
        "december": 12, "dec": 12
    ]

    /// Gregorian weekday numbers (Sunday = 1).
    private static let weekdayByName: [String: Int] = [
        "sunday": 1, "sun": 1, "monday": 2, "mon": 2, "tuesday": 3, "tue": 3, "tues": 3,
        "wednesday": 4, "wed": 4, "thursday": 5, "thu": 5, "thurs": 5, "friday": 6, "fri": 6,
        "saturday": 7, "sat": 7
    ]
    // MARK: - Timezone queries

    private static func parseTimezone(_ query: String, echo: String, now: Date, calendar: Calendar) -> CalcResult? {
        let q = query.lowercased()
        
        // 1. time diff <place> OR diff <place>
        if q.hasPrefix("time diff ") || q.hasPrefix("diff ") {
            let placeStr = q.hasPrefix("diff ") ? String(q.dropFirst(5)) : String(q.dropFirst(10))
            if let tz = resolveCityToIANA(placeStr) {
                let diffSeconds = tz.secondsFromGMT(for: now) - calendar.timeZone.secondsFromGMT(for: now)
                let diffHours = Double(diffSeconds) / 3600.0
                let sign = diffHours >= 0 ? "+" : ""
                let display = "\(sign)\(CalcFormatter.display(diffHours)) hours"
                return CalcResult(
                    expression: echo,
                    sourceBadge: tzCityName(calendar.timeZone),
                    targetBadge: tzCityName(tz),
                    payload: .value(display: display, copyText: display)
                )
            }
        }
        
        // 2. <time> in <place> OR time in <place> OR time in <delay> in <place>
        if let lastIn = q.range(of: " in ", options: .backwards) {
            let left = String(q[..<lastIn.lowerBound]).trimmingCharacters(in: .whitespaces)
            let placeStr = String(q[lastIn.upperBound...]).trimmingCharacters(in: .whitespaces)
            
            if let targetTz = resolveCityToIANA(placeStr) {
                var targetCalendar = calendar
                targetCalendar.timeZone = targetTz
                
                // A) "time in <place>"
                if left == "time" {
                    let display = tzTimeString(now, calendar: targetCalendar)
                    return CalcResult(
                        expression: echo,
                        sourceBadge: tzCityName(calendar.timeZone),
                        targetBadge: tzCityName(targetTz),
                        payload: .value(display: display, copyText: display)
                    )
                }
                
                // B) "time in <delay> in <place>"
                if left.hasPrefix("time in ") {
                    let delayStr = String(left.dropFirst(8))
                    if let duration = parseDurationPhrase(delayStr),
                       let targetDate = calendar.date(byAdding: duration.component, value: duration.count, to: now) {
                        let display = tzTimeString(targetDate, calendar: targetCalendar)
                        return CalcResult(
                            expression: echo,
                            sourceBadge: tzCityName(calendar.timeZone),
                            targetBadge: tzCityName(targetTz),
                            payload: .value(display: display, copyText: display)
                        )
                    }
                }
                
                // C) "<time> <sourceTz> in <targetTz>"
                let leftWords = left.split(separator: " ").map(String.init)
                if leftWords.count >= 2, let sourceTz = resolveCityToIANA(leftWords.last!) {
                    let timePhrase = leftWords.dropLast().joined(separator: " ")
                    var sourceCalendar = calendar
                    sourceCalendar.timeZone = sourceTz
                    
                    if let moment = parseMoment(timePhrase, now: now, calendar: sourceCalendar) {
                        let display = tzTimeString(moment.date, calendar: targetCalendar)
                        return CalcResult(
                            expression: echo,
                            sourceBadge: tzCityName(sourceTz),
                            targetBadge: tzCityName(targetTz),
                            payload: .value(display: display, copyText: display)
                        )
                    }
                }
            }
        }
        
        return nil
    }
    
    private static let tzAliases: [String: String] = [
        "ldn": "Europe/London",
        "sf": "America/Los_Angeles",
        "sanfrancisco": "America/Los_Angeles",
        "jfk": "America/New_York",
        "dubai": "Asia/Dubai",
    ]

    private static func resolveCityToIANA(_ city: String) -> TimeZone? {
        let normalized = city.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: nil)
            .replacingOccurrences(of: " ", with: "")
        
        if let alias = tzAliases[normalized] {
            return TimeZone(identifier: alias)
        }
        
        for identifier in TimeZone.knownTimeZoneIdentifiers {
            let parts = identifier.split(separator: "/")
            if let last = parts.last {
                let cityPart = String(last).folding(options: [.diacriticInsensitive, .caseInsensitive], locale: nil)
                    .replacingOccurrences(of: "_", with: "")
                    .replacingOccurrences(of: " ", with: "")
                if cityPart == normalized {
                    return TimeZone(identifier: identifier)
                }
            }
        }
        return nil
    }
    
    private static func tzCityName(_ tz: TimeZone) -> String {
        if tz.secondsFromGMT() == 0, !tz.identifier.contains("/") { return "UTC" }
        if let last = tz.identifier.split(separator: "/").last {
            return String(last).replacingOccurrences(of: "_", with: " ")
        }
        return tz.identifier
    }
    
    private static func tzTimeString(_ date: Date, calendar: Calendar) -> String {
        let formatter = DateFormatter()
        formatter.calendar = calendar
        formatter.timeZone = calendar.timeZone
        formatter.locale = calendar.locale ?? Locale(identifier: "en_US")
        formatter.dateFormat = "HH:mm"
        return formatter.string(from: date)
    }
}
