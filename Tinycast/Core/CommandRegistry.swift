import Foundation

/// Built-in launcher actions surfaced alongside user-authored commands, with dispatch in `AppCore.runCommand`.
enum CommandID: String, CaseIterable, Sendable {
    case calculatorHistory = "command:calculator-history"
    case clipboardHistory = "command:clipboard-history"
    case searchEmoji = "command:search-emoji"
    case createQuicklink = "command:create-quicklink"
    case searchQuicklinks = "command:search-quicklinks"
    case importQuicklinks = "command:import-quicklinks"
    case exportQuicklinks = "command:export-quicklinks"
    case exportSettings = "command:export-settings"
    case importSettings = "command:import-settings"
    case importFromRaycast = "command:import-from-raycast"
    case settings = "command:settings"
    case about = "command:about"
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
    // Low Power Mode toggle — a System-state command like `toggleCaffeination`. macOS exposes no
    // public toggle API, so `LowPowerController` flips it via `osascript … with administrator
    // privileges` (the standard GUI admin-password gate); read state is `ProcessInfo`.
    case toggleLowPower = "command:toggle-low-power"

    var name: String {
        switch self {
        case .calculatorHistory: return "Calculator History"
        case .clipboardHistory: return "Clipboard History"
        case .searchEmoji: return "Search Emoji & Symbols"
        case .createQuicklink: return "Create Quicklink"
        case .searchQuicklinks: return "Search Quicklinks"
        case .importQuicklinks: return "Import Quicklinks"
        case .exportQuicklinks: return "Export Quicklinks"
        case .exportSettings: return "Export Settings"
        case .importSettings: return "Import Settings"
        case .importFromRaycast: return "Import from Raycast"
        case .settings: return "Settings"
        case .about: return "About Tinycast"
        case .quit: return "Quit Tinycast"
        case .toggleMicrophone: return "Toggle Audio Input"
        case .setMicrophoneLevel: return "Set Microphone Level"
        case .caffeinate: return "Caffeinate"
        case .decaffeinate: return "Decaffeinate"
        case .toggleCaffeination: return "Toggle Caffeination"
        case .caffeinateFor: return "Caffeinate for…"
        case .caffeinateUntil: return "Caffeinate Until"
        case .caffeinateWhile: return "Caffeinate While"
        case .toggleLowPower: return "Toggle Low Power Mode"
        case .cameraPreview: return "Camera Preview"
        }
    }

    var sfSymbol: String {
        switch self {
        case .calculatorHistory: return "plus.forwardslash.minus"
        case .clipboardHistory: return "doc.on.clipboard"
        case .searchEmoji: return "face.smiling"
        case .createQuicklink: return "link.badge.plus"
        case .searchQuicklinks: return Quicklink.sfSymbol
        case .importQuicklinks: return "square.and.arrow.down"
        case .exportQuicklinks: return "square.and.arrow.up"
        case .exportSettings: return "square.and.arrow.up"
        case .importSettings: return "square.and.arrow.down"
        case .importFromRaycast: return "arrow.down.doc"
        case .settings: return "gearshape"
        case .about: return "info.circle"
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
        case .toggleLowPower: return "battery.0"
        }
    }

    /// Only meaningful while Quicklinks is on, so `AppIndex` drops these from the built-in slice
    /// when the feature is off.
    var isQuicklinkCommand: Bool {
        switch self {
        case .createQuicklink, .searchQuicklinks, .importQuicklinks, .exportQuicklinks: return true
        default: return false
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
