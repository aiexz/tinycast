import AppKit
@preconcurrency import EventKit
import SwiftUI

struct CalendarInfo: Identifiable, Equatable, Sendable {
    let id: String
    let title: String
    let color: Color
}

struct CalendarEvent: Identifiable, Equatable, Sendable {
    let id: String
    let eventIdentifier: String
    let calendarItemIdentifier: String
    let title: String
    let startDate: Date
    let endDate: Date
    let isAllDay: Bool
    let calendarTitle: String
    let calendarColor: Color
    let location: String?
    let notes: String?
    let attendeeNames: [String]
    let attendeeEmails: [String]
    let meetingURL: URL?

    var attendeeCount: Int { max(attendeeNames.count, attendeeEmails.count) }

    var detailText: String {
        var lines = [title, Self.intervalFormatter.string(from: startDate, to: endDate)]
        if let location, !location.isEmpty { lines.append(location) }
        if !attendeeNames.isEmpty { lines.append(attendeeNames.joined(separator: ", ")) }
        if let meetingURL { lines.append(meetingURL.absoluteString) }
        return lines.joined(separator: "\n")
    }

    private static let intervalFormatter: DateIntervalFormatter = {
        let formatter = DateIntervalFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        return formatter
    }()
}

@MainActor
final class CalendarStore: ObservableObject {
    @Published private(set) var authorizationStatus = EKEventStore.authorizationStatus(for: .event)
    @Published private(set) var calendars: [CalendarInfo] = []
    @Published private(set) var events: [CalendarEvent] = []
    @Published private(set) var isLoading = false
    @Published private(set) var errorMessage: String?

    private let eventStore = EKEventStore()
    private unowned let settings: AppSettings
    private var changeToken: NotificationToken?

    init(settings: AppSettings) {
        self.settings = settings
        let center = NotificationCenter.default
        changeToken = NotificationToken(
            center.addObserver(forName: .EKEventStoreChanged, object: eventStore, queue: .main) {
                [weak self] _ in
                Task { @MainActor [weak self] in self?.refresh() }
            },
            center: center)
    }

    func requestAccessAndRefresh() async {
        authorizationStatus = EKEventStore.authorizationStatus(for: .event)
        if authorizationStatus == .notDetermined {
            do {
                _ = try await eventStore.requestFullAccessToEvents()
            } catch {
                errorMessage = error.localizedDescription
            }
            authorizationStatus = EKEventStore.authorizationStatus(for: .event)
        }
        refresh()
    }

    func refresh() {
        authorizationStatus = EKEventStore.authorizationStatus(for: .event)
        guard authorizationStatus == .fullAccess else {
            calendars = []
            events = []
            isLoading = false
            return
        }

        isLoading = true
        errorMessage = nil
        let sourceCalendars = eventStore.calendars(for: .event).sorted {
            $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending
        }
        calendars = sourceCalendars.map {
            CalendarInfo(id: $0.calendarIdentifier, title: $0.title, color: Self.color($0.cgColor))
        }

        let enabledIDs = Set(settings.calendarEnabledIDs)
        let selectedCalendars = enabledIDs.isEmpty
            ? sourceCalendars : sourceCalendars.filter { enabledIDs.contains($0.calendarIdentifier) }
        let calendar = Calendar.current
        let start = calendar.startOfDay(for: Date())
        let end = calendar.date(byAdding: .month, value: 3, to: start) ?? start.addingTimeInterval(7_776_000)
        let predicate = eventStore.predicateForEvents(withStart: start, end: end, calendars: selectedCalendars)
        events = eventStore.events(matching: predicate)
            .filter { $0.status != .canceled }
            .map(Self.snapshot)
            .sorted { lhs, rhs in
                lhs.startDate == rhs.startDate
                    ? lhs.title.localizedCaseInsensitiveCompare(rhs.title) == .orderedAscending
                    : lhs.startDate < rhs.startDate
            }
        isLoading = false
    }

    func filteredEvents(query: String) -> [CalendarEvent] {
        let needle = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !needle.isEmpty else { return events }
        return events.filter {
            $0.title.localizedCaseInsensitiveContains(needle)
                || $0.calendarTitle.localizedCaseInsensitiveContains(needle)
                || ($0.location?.localizedCaseInsensitiveContains(needle) ?? false)
        }
    }

    func openInCalendar(_ event: CalendarEvent) {
        let date = Self.calendarURLDateFormatter.string(from: event.startDate)
        var components = URLComponents()
        components.scheme = "ical"
        components.host = "ekevent"
        components.path = "/\(date)/\(event.calendarItemIdentifier)"
        components.queryItems = [
            URLQueryItem(name: "method", value: "show"),
            URLQueryItem(name: "options", value: "more"),
        ]
        if let url = components.url { NSWorkspace.shared.open(url) }
    }

    func join(_ event: CalendarEvent) {
        guard let url = event.meetingURL else { return }
        NSWorkspace.shared.open(url)
    }

    func copyDetails(_ event: CalendarEvent) { copy(event.detailText) }
    func copyTitle(_ event: CalendarEvent) { copy(event.title) }

    func emailAttendees(_ event: CalendarEvent) {
        guard !event.attendeeEmails.isEmpty else { return }
        var components = URLComponents()
        components.scheme = "mailto"
        components.path = event.attendeeEmails.joined(separator: ",")
        components.queryItems = [URLQueryItem(name: "subject", value: event.title)]
        if let url = components.url { NSWorkspace.shared.open(url) }
    }

    private func copy(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    private nonisolated static let calendarURLDateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "yyyyMMdd'T'HHmmss'Z'"
        return formatter
    }()

    private nonisolated static func snapshot(_ event: EKEvent) -> CalendarEvent {
        let attendees = event.attendees ?? []
        let names = attendees.compactMap(\.name)
        let emails = attendees.compactMap { participant -> String? in
            let url = participant.url
            guard url.scheme?.lowercased() == "mailto" else { return nil }
            return url.path.removingPercentEncoding ?? url.path
        }
        let occurrence = event.occurrenceDate ?? event.startDate ?? .distantPast
        let eventIdentifier = event.eventIdentifier ?? event.calendarItemIdentifier
        let candidates = [event.url?.absoluteString, event.location, event.notes].compactMap { $0 }
        return CalendarEvent(
            id: "\(eventIdentifier)#\(occurrence.timeIntervalSinceReferenceDate)",
            eventIdentifier: eventIdentifier,
            calendarItemIdentifier: event.calendarItemIdentifier,
            title: event.title?.isEmpty == false ? event.title : "Untitled Event",
            startDate: event.startDate,
            endDate: event.endDate,
            isAllDay: event.isAllDay,
            calendarTitle: event.calendar.title,
            calendarColor: color(event.calendar.cgColor),
            location: event.location,
            notes: event.notes,
            attendeeNames: names,
            attendeeEmails: emails,
            meetingURL: meetingURL(in: candidates))
    }

    private nonisolated static func color(_ cgColor: CGColor) -> Color {
        Color(nsColor: NSColor(cgColor: cgColor) ?? .systemBlue)
    }

    private nonisolated static func meetingURL(in values: [String]) -> URL? {
        for value in values {
            let range = NSRange(value.startIndex..<value.endIndex, in: value)
            guard let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue) else { continue }
            for match in detector.matches(in: value, range: range) {
                guard let url = match.url, let host = url.host?.lowercased(), ["http", "https"].contains(url.scheme?.lowercased() ?? "") else { continue }
                if meetingHosts.contains(where: { host == $0 || host.hasSuffix(".\($0)") }) { return url }
            }
        }
        return nil
    }

    private nonisolated static let meetingHosts = [
        "zoom.us", "meet.google.com", "teams.microsoft.com", "teams.live.com", "app.slack.com",
        "webex.com", "facetime.apple.com", "join.skype.com", "bluejeans.com", "chime.aws",
        "whereby.com", "meet.jit.si", "around.co", "chorus.ai", "riverside.fm", "streamyard.com",
    ]
}
