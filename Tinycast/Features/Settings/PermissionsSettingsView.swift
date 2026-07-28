import Combine
import EventKit
import SwiftUI

struct PermissionsSettingsView: View {
    @State private var accessibilityTrusted = Permissions.isAccessibilityTrusted()
    @State private var calendarStatus = Permissions.calendarStatus()
    private let refreshTimer = Timer.publish(every: 1, on: .main, in: .common).autoconnect()
    @EnvironmentObject private var calendarStore: CalendarStore
    @ObservedObject private var settings = AppCore.shared.settings

    var body: some View {
        SettingsPane(
            title: "Permissions",
            subtitle: "Access Tinycast needs to work with other apps."
        ) {
            SettingsCard(header: "Accessibility") {
                SettingsRow(
                    title: "Accessibility",
                    subtitle: "Lets Tinycast paste a clipboard item into the app you were using.",
                    systemImage: "accessibility",
                    tint: .blue
                ) {
                    statusBadge
                }
                SettingsDivider()
                SettingsRow(
                    title: accessibilityTrusted ? "Manage in System Settings" : "Grant access",
                    subtitle: "Opens Privacy & Security › Accessibility.",
                    systemImage: "arrow.up.forward.app",
                    tint: .secondary
                ) {
                    Button(accessibilityTrusted ? "Open…" : "Open Settings…") {
                        Permissions.openAccessibilitySettings()
                    }
                }
            }
            SettingsCard(header: "Calendar") {
                SettingsRow(
                    title: "Calendar",
                    subtitle: "Shows upcoming events and meeting links from macOS Calendar.",
                    systemImage: "calendar",
                    tint: .red
                ) {
                    permissionBadge(
                        granted: calendarStatus == .fullAccess,
                        text: calendarStatus == .fullAccess ? "Granted" : "Not granted")
                }
                SettingsDivider()
                SettingsRow(
                    title: calendarStatus == .notDetermined ? "Grant access from My Schedule" : "Manage in System Settings",
                    subtitle: calendarStatus == .notDetermined
                        ? "Open My Schedule from the launcher to request access."
                        : "Opens Privacy & Security › Calendars.",
                    systemImage: "arrow.up.forward.app",
                    tint: .secondary
                ) {
                    if calendarStatus != .notDetermined {
                        Button("Open Settings…") { Permissions.openCalendarSettings() }
                    }
                }
            }
            if calendarStatus == .fullAccess, !calendarStore.calendars.isEmpty {
                SettingsCard(header: "Visible Calendars") {
                    ForEach(Array(calendarStore.calendars.enumerated()), id: \.element.id) { index, calendar in
                        SettingsRow(
                            title: calendar.title,
                            systemImage: "calendar",
                            tint: calendar.color
                        ) {
                            Toggle("", isOn: calendarBinding(calendar.id))
                                .labelsHidden()
                        }
                        if index < calendarStore.calendars.count - 1 { SettingsDivider() }
                    }
                }
            }
        }
        .onAppear {
            refreshPermissions()
            calendarStore.refresh()
        }
        .onReceive(refreshTimer) { _ in refreshPermissions() }
    }

    private var statusBadge: some View {
        permissionBadge(
            granted: accessibilityTrusted,
            text: accessibilityTrusted ? "Granted" : "Not granted")
    }

    private func permissionBadge(granted: Bool, text: String) -> some View {
        HStack(spacing: Theme.Spacing.xs + 1) {
            Image(systemName: granted ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
            Text(text)
        }
        .font(.caption.weight(.semibold))
        .foregroundStyle(granted ? Color.green : Color.orange)
        .padding(.horizontal, Theme.Spacing.md)
        .padding(.vertical, Theme.Spacing.xs)
        .background(Capsule().fill((granted ? Color.green : Color.orange).opacity(0.14)))
    }

    private func calendarBinding(_ id: String) -> Binding<Bool> {
        Binding(
            get: {
                settings.calendarEnabledIDs.isEmpty || settings.calendarEnabledIDs.contains(id)
            },
            set: { enabled in
                var selected = settings.calendarEnabledIDs.isEmpty
                    ? Set(calendarStore.calendars.map(\.id)) : Set(settings.calendarEnabledIDs)
                if enabled { selected.insert(id) } else { selected.remove(id) }
                settings.calendarEnabledIDs = selected.count == calendarStore.calendars.count
                    ? [] : Array(selected).sorted()
                calendarStore.refresh()
            })
    }

    private func refreshPermissions() {
        accessibilityTrusted = Permissions.isAccessibilityTrusted()
        calendarStatus = Permissions.calendarStatus()
    }
}
