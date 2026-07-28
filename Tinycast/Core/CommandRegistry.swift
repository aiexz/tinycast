import Foundation

/// App-internal launcher actions surfaced as a "Commands" category; each is a synthetic `AppEntry` (kind `.command`, no bundle ID) so existing `AppEntry` plumbing applies, with dispatch in `AppCore.runCommand`.
enum CommandID: String, CaseIterable, Sendable {
    case calculatorHistory = "command:calculator-history"
    case clipboardHistory = "command:clipboard-history"
    case searchEmoji = "command:search-emoji"
    case mySchedule = "command:my-schedule"
    case exportSettings = "command:export-settings"
    case importSettings = "command:import-settings"
    case importFromRaycast = "command:import-from-raycast"
    case settings = "command:settings"
    case about = "command:about"
    case quitAllApps = "command:quit-all-apps"
    case quit = "command:quit"
    // Microphone + caffeination launcher commands (shared contract). The microphone
    // level/caffeination duration args aren't carried by `AppEntry`; the immediate
    // toggle/caffeinate actions dispatch straight to the controllers, and the
    // configuration commands switch the palette into the matching `PaletteMode`
    // (`setMicrophoneLevel/caffeinateFor/Until/While`) where the user picks a
    // level/duration/app via SystemCommandViews.
    case toggleMicrophone = "command:toggle-microphone"
    case setMicrophoneLevel = "command:set-microphone-level"
    case caffeinate = "command:caffeinate"
    case decaffeinate = "command:decaffeinate"
    case toggleCaffeination = "command:toggle-caffeination"
    case caffeinateFor = "command:caffeinate-for"
    case caffeinateUntil = "command:caffeinate-until"
    case caffeinateWhile = "command:caffeinate-while"
    case cameraPreview = "command:camera-preview"

    var name: String {
        switch self {
        case .calculatorHistory: return "Calculator History"
        case .clipboardHistory: return "Clipboard History"
        case .searchEmoji: return "Search Emoji & Symbols"
        case .mySchedule: return "My Schedule"
        case .exportSettings: return "Export Settings"
        case .importSettings: return "Import Settings"
        case .importFromRaycast: return "Import from Raycast"
        case .settings: return "Settings"
        case .about: return "About Tinycast"
        case .quitAllApps: return "Quit All Applications"
        case .quit: return "Quit Tinycast"
        case .toggleMicrophone: return "Toggle Audio Input"
        case .setMicrophoneLevel: return "Set Microphone Level"
        case .caffeinate: return "Caffeinate"
        case .decaffeinate: return "Decaffeinate"
        case .toggleCaffeination: return "Toggle Caffeination"
        case .caffeinateFor: return "Caffeinate for…"
        case .caffeinateUntil: return "Caffeinate Until"
        case .caffeinateWhile: return "Caffeinate While"
        case .cameraPreview: return "Camera Preview"
        }
    }

    var sfSymbol: String {
        switch self {
        case .calculatorHistory: return "plus.forwardslash.minus"
        case .clipboardHistory: return "doc.on.clipboard"
        case .searchEmoji: return "face.smiling"
        case .mySchedule: return "calendar"
        case .exportSettings: return "square.and.arrow.up"
        case .importSettings: return "square.and.arrow.down"
        case .importFromRaycast: return "arrow.down.doc"
        case .settings: return "gearshape"
        case .about: return "info.circle"
        case .quitAllApps: return "xmark.circle"
        case .quit: return "power"
        case .toggleMicrophone: return "mic.slash"
        case .setMicrophoneLevel: return "slider.vertical.3"
        case .caffeinate: return "cup.and.saucer.fill"
        case .decaffeinate: return "cup.and.saucer"
        case .toggleCaffeination: return "circle.dotted"
        case .caffeinateFor: return "timer"
        case .caffeinateUntil: return "clock.badge.checkmark"
        case .cameraPreview: return "video"
        case .caffeinateWhile: return "macwindow"
        }
    }
}

enum CommandRegistry {
    /// Sorted by name to keep the AppIndex sort invariant; the URL is a placeholder since commands are never launched from disk.
    nonisolated static let all: [AppEntry] =
        CommandID.allCases
        .map { id in
            AppEntry(
                id: id.rawValue, name: id.name,
                url: URL(
                    string: "tinycast://" + id.rawValue.replacingOccurrences(of: ":", with: "/"))!,
                bundleID: nil, kind: .command)
        }
        .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }

    static func command(for entry: AppEntry) -> CommandID? {
        CommandID(rawValue: entry.id)
    }
}
