import AppKit
import SwiftUI

struct SystemCommandView: View {
    let mode: PaletteMode
    let query: String
    let selection: Int
    @ObservedObject private var microphone = AppCore.shared.microphoneController
    @ObservedObject private var coffee = AppCore.shared.caffeinationController
    @State private var untilDate = Date().addingTimeInterval(3600)

    var body: some View {
        ScrollView {
            VStack(spacing: Theme.Spacing.xl) {
                switch mode {
                case .setMicrophoneLevel:
                    commandCard(title: "Set Level of Audio Input", detail: "Enter 0–100, or leave empty for the default (100).", action: "Set Level") {
                        SystemCommandActions.submit(mode: mode, query: query, untilDate: untilDate)
                    }
                case .caffeinateFor:
                    commandCard(title: "Caffeinate for ...", detail: "Enter hours, minutes, and seconds as three whole numbers, for example: 1 30 0.", action: "Caffeinate") {
                        SystemCommandActions.submit(mode: mode, query: query, untilDate: untilDate)
                    }
                case .caffeinateUntil:
                    SettingsCard(header: "Caffeinate Until") {
                        SettingsRow(title: "Typed Time", subtitle: "Type a time such as 5pm in the search field, or pick a date and time.", systemImage: "clock") {
                            Button("Use Typed Time") { SystemCommandActions.submit(mode: mode, query: query, untilDate: untilDate) }
                                .disabled(query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                        }
                        SettingsDivider()
                        SettingsRow(title: "Date and Time", systemImage: "calendar") {
                            DatePicker("", selection: $untilDate, in: Date().addingTimeInterval(60)...)
                                .labelsHidden()
                            Button("Caffeinate") { SystemCommandActions.submit(mode: mode, query: "", untilDate: untilDate) }
                        }
                    }
                case .caffeinateWhile:
                    runningApps
                default:
                    EmptyView()
                }
            }
            .padding(Theme.Spacing.xxl)
        }
        .edgeDissolve()
        .thinScrollbar()
    }

    private func commandCard(title: String, detail: String, action: String, perform: @escaping () -> Void) -> some View {
        SettingsCard(header: title) {
            SettingsRow(title: title, subtitle: detail, systemImage: mode.systemImage) {
                Button(action, action: perform)
            }
        }
    }

    private var runningApps: some View {
        let apps = SystemCommandActions.runningApps
        return SettingsCard(header: "Caffeinate While") {
            if apps.isEmpty {
                SettingsRow(title: "No running applications", systemImage: "macwindow") { EmptyView() }
            } else {
                ForEach(Array(apps.enumerated()), id: \.element.id) { index, app in
                    if index > 0 { SettingsDivider() }
                    SettingsRow(title: app.name, systemImage: "macwindow") {
                        Button("Caffeinate") { Task { await coffee.caffeinateWhileApp(.bundleID(app.id)) } }
                    }
                }
            }
        }
    }
}
@MainActor
enum SystemCommandActions {
    struct RunningApp: Identifiable { let id: String; let name: String }

    static var runningApps: [RunningApp] {
        NSWorkspace.shared.runningApplications.compactMap { app in
            guard app.activationPolicy == .regular, let id = app.bundleIdentifier, let name = app.localizedName else { return nil }
            return RunningApp(id: id, name: name)
        }.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    static func submit(mode: PaletteMode, query: String, untilDate: Date = Date()) {
        let text = query.trimmingCharacters(in: .whitespacesAndNewlines)
        switch mode {
        case .setMicrophoneLevel:
            let level = text.isEmpty ? MicrophoneController.defaultLevel : Int(text)
            guard let level, (0...100).contains(level) else { return }
            Task { await AppCore.shared.microphoneController.setLevel(level) }
            AppCore.shared.hidePalette(restoreFocus: false)
        case .caffeinateFor:
            let values = text.split(whereSeparator: \.isWhitespace).map(String.init)
            guard !values.isEmpty, values.count <= 3,
                values.allSatisfy({ Int($0).map { $0 >= 0 } == true })
            else { return }
            let numbers = values.map { Int($0)! } + Array(repeating: 0, count: 3 - values.count)
            let seconds = numbers[0] * 3600 + numbers[1] * 60 + numbers[2]
            guard seconds > 0 else { return }
            Task { await AppCore.shared.caffeinationController.caffeinate(for: TimeInterval(seconds)) }
            AppCore.shared.hidePalette(restoreFocus: false)
        case .caffeinateUntil:
            let target = text.isEmpty ? untilDate : parseTime(text)
            guard let target, target > Date() else { return }
            Task { await AppCore.shared.caffeinationController.caffeinate(until: target) }
            AppCore.shared.hidePalette(restoreFocus: false)
        default:
            break
        }
    }

    static func parseTime(_ text: String) -> Date? {
        let pattern = #"^(\d{1,2})(?::(\d\d))?\s*(am|pm)?$"#
        guard let regex = try? NSRegularExpression(pattern: pattern, options: .caseInsensitive),
            let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text))
        else { return nil }
        func part(_ index: Int) -> String? {
            let range = match.range(at: index)
            guard range.location != NSNotFound, let swiftRange = Range(range, in: text) else { return nil }
            return String(text[swiftRange])
        }
        guard let hourText = part(1), var hour = Int(hourText) else { return nil }
        let minute = part(2).flatMap(Int.init) ?? 0
        let marker = part(3)?.lowercased()
        if marker == "pm", hour < 12 { hour += 12 }
        if marker == "am", hour == 12 { hour = 0 }
        guard hour <= 24, minute <= 59 else { return nil }
        var target = Calendar.current.date(bySettingHour: hour, minute: minute, second: 0, of: Date())!
        let explicit = marker != nil || hour > 12 || hourText.hasPrefix("0")
        while target <= Date() { target = target.addingTimeInterval(explicit ? 86_400 : 43_200) }
        return target
    }
}
