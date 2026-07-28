import AppKit
import SwiftUI

struct CalendarScheduleView: View {
    let events: [CalendarEvent]
    let selectedID: CalendarEvent.ID?
    let scrollToken: UUID
    let showsSummary: Bool
    let onSelect: (CalendarEvent) -> Void
    let onActivate: (CalendarEvent) -> Void
    let onActions: (CalendarEvent) -> Void

    private enum Row: Identifiable {
        case summary(CalendarEvent)
        case header(String)
        case event(CalendarEvent)

        var id: String {
            switch self {
            case .summary(let event): return "summary-\(event.id)"
            case .header(let title): return "header-\(title)"
            case .event(let event): return event.id
            }
        }
    }

    private var rows: [Row] {
        var result: [Row] = []
        if showsSummary, let next = events.first(where: { $0.endDate > Date() }) { result.append(.summary(next)) }
        for (index, group) in groups.enumerated() {
            result.append(.header(group.title))
            result.append(contentsOf: group.events.map(Row.event))
            if index == groups.count - 1 { break }
        }
        return result
    }

    private var groups: [(title: String, events: [CalendarEvent])] {
        let grouped = Dictionary(grouping: events, by: { Self.sectionTitle(for: $0.startDate) })
        var seen = Set<String>()
        return events.compactMap { event in
            let title = Self.sectionTitle(for: event.startDate)
            guard seen.insert(title).inserted, let group = grouped[title] else { return nil }
            return (title, group)
        }
    }

    var body: some View {
        let rows = rows
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(rows) { row in
                        switch row {
                        case .summary(let event):
                            CalendarSummary(event: event)
                                .padding(.horizontal, Theme.Spacing.md)
                                .padding(.bottom, Theme.Spacing.md)
                        case .header(let title):
                            SectionHeader(title: title, isFirst: row.id == rows.first?.id)
                        case .event(let event):
                            CalendarEventRow(event: event, selected: event.id == selectedID)
                                .contentShape(Rectangle())
                                .onTapGesture {
                                    onSelect(event)
                                    onActivate(event)
                                }
                                .onRightClick {
                                    onSelect(event)
                                    onActions(event)
                                }
                        }
                    }
                }
                .padding(.horizontal, Theme.Spacing.md)
                .padding(.top, Theme.Spacing.xs)
                .padding(.bottom, Theme.Spacing.md)
                .hideNativeScrollers()
            }
            .edgeDissolve()
            .thinScrollbar()
            .onChange(of: scrollToken) {
                if let selectedID { proxy.scrollTo(selectedID, anchor: .center) }
            }
        }
    }

    private static func sectionTitle(for date: Date) -> String {
        let calendar = Calendar.current
        let day = calendar.startOfDay(for: date)
        let today = calendar.startOfDay(for: Date())
        if day == today { return "Today" }
        if day == calendar.date(byAdding: .day, value: 1, to: today) { return "Tomorrow" }

        let thisWeek = calendar.dateInterval(of: .weekOfYear, for: today)
        if let thisWeek, thisWeek.contains(day) {
            return day.formatted(.dateTime.weekday(.wide))
        }
        if let nextWeekStart = thisWeek?.end,
            let nextWeek = calendar.dateInterval(of: .weekOfYear, for: nextWeekStart),
            nextWeek.contains(day)
        {
            return "Next Week"
        }
        return day.formatted(.dateTime.month(.wide))
    }
}

private struct CalendarSummary: View {
    let event: CalendarEvent

    var body: some View {
        HStack(alignment: .top, spacing: Theme.Spacing.xxl) {
            VStack(alignment: .leading, spacing: Theme.Spacing.xs) {
                Text(greeting).font(.headline)
                Text(summary).font(.callout).foregroundStyle(.secondary)
            }
            Spacer()
            VStack(alignment: .leading, spacing: Theme.Spacing.xs) {
                Text("Next up").font(.callout).foregroundStyle(.secondary)
                Text(nextText).font(.headline).lineLimit(2)
            }
            .frame(maxWidth: 300, alignment: .leading)
        }
        .padding(Theme.Spacing.xxl)
        .background(
            RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous)
                .fill(Theme.Colors.cardFill)
        )
        .overlay(
            RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous)
                .strokeBorder(Theme.Colors.cardStroke, lineWidth: 1)
        )
    }

    private var greeting: String {
        switch Calendar.current.component(.hour, from: Date()) {
        case 0..<12: return "Good Morning"
        case 12..<18: return "Good Afternoon"
        default: return "Good Evening"
        }
    }

    private var summary: String {
        let count = AppCore.shared.calendarStore.events.filter { Calendar.current.isDateInToday($0.startDate) }.count
        return count == 1 ? "You have one event planned for today." : "You have \(count) events planned for today."
    }

    private var nextText: String {
        if event.startDate <= Date() && event.endDate > Date() { return "\(event.title) is happening now." }
        return "\(event.title) starts \(event.startDate.formatted(.relative(presentation: .named)))."
    }
}

private struct CalendarEventRow: View {
    let event: CalendarEvent
    let selected: Bool
    @State private var hovered = false

    private var fill: Color {
        if selected { return Theme.Colors.selection }
        if hovered { return Theme.Colors.rowHover }
        return .clear
    }

    var body: some View {
        HStack(spacing: Theme.Spacing.lg) {
            Circle()
                .stroke(event.calendarColor, lineWidth: 2)
                .frame(width: 12, height: 12)
            Text(timeText)
                .font(Theme.Typography.rowTitle.monospacedDigit())
                .foregroundStyle(event.isAllDay ? Theme.Colors.textSecondary : .primary)
                .frame(width: 150, alignment: .leading)
            Text(event.title)
                .font(Theme.Typography.rowTitle)
                .lineLimit(1)
            Spacer()
            if event.attendeeCount > 0 {
                Label("\(event.attendeeCount)", systemImage: "person.circle")
                    .font(Theme.Typography.rowTrailing)
                    .foregroundStyle(.secondary)
                    .labelStyle(.titleAndIcon)
            }
            if event.meetingURL != nil {
                Image(systemName: "video")
                    .font(Theme.Typography.rowTrailing)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, Theme.Spacing.md)
        .padding(.vertical, Theme.Spacing.sm)
        .background(RoundedRectangle(cornerRadius: Theme.Radius.row, style: .continuous).fill(fill))
        .armedHover($hovered)
    }

    private var timeText: String {
        if event.isAllDay { return "All day" }
        let start = event.startDate.formatted(date: .omitted, time: .shortened)
        let end = event.endDate.formatted(date: .omitted, time: .shortened)
        return "\(start) – \(end)"
    }
}
struct CalendarPermissionView: View {
    var denied = false
    let action: () -> Void

    var body: some View {
        VStack(spacing: Theme.Spacing.xl) {
            Image(systemName: denied ? "calendar.badge.exclamationmark" : "calendar")
                .font(.largeTitle)
                .symbolRenderingMode(.hierarchical)
                .foregroundStyle(.secondary)
            Text(denied ? "Calendar access is off" : "Connect your calendar")
                .font(.headline)
            Text(denied
                ? "Allow Tinycast in Privacy & Security › Calendars to see your schedule."
                : "Tinycast reads the calendars already configured on your Mac.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 360)
            Button(denied ? "Open System Settings" : "Allow Calendar Access", action: action)
                .buttonStyle(.borderedProminent)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}


@MainActor
enum CalendarActionsMenu {
    static func content(event: CalendarEvent, store: CalendarStore) -> PopoverMenuContent {
        var items = [
            PopoverMenuItem(title: "Open in Calendar", systemImage: "calendar", shortcut: "↵") {
                store.openInCalendar(event)
            }
        ]
        if event.meetingURL != nil {
            items.append(
                PopoverMenuItem(title: "Join Meeting", systemImage: "video", shortcut: "⌘↵") {
                    store.join(event)
                })
        }
        items.append(
            PopoverMenuItem(title: "Copy Event Details", systemImage: "doc.on.doc", shortcut: "⌘.") {
                store.copyDetails(event)
            })
        items.append(
            PopoverMenuItem(title: "Copy Event Title", systemImage: "textformat", shortcut: "⌘⇧.") {
                store.copyTitle(event)
            })
        if !event.attendeeEmails.isEmpty {
            items.append(
                PopoverMenuItem(title: "Email Attendees", systemImage: "envelope", shortcut: "⌘⇧E") {
                    store.emailAttendees(event)
                })
        }
        return PopoverMenuContent(header: event.title, items: items)
    }
}
