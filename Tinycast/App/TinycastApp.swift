import SwiftUI

@main
struct TinycastApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    // `@AppStorage` republishes only when the value changes, avoiding a scene ⇄ binding feedback loop.
    @AppStorage(SettingsKey.showInMenuBar) private var showInMenuBar = true

    // Channel-aware: "Tinycast", "Tinycast Dev", or "Tinycast Beta".
    private let appName = Bundle.main.appDisplayName

    var body: some Scene {
        MenuBarExtra(
            appName, systemImage: "macwindow.on.rectangle", isInserted: $showInMenuBar
        ) {
            Button("Open \(appName)") { AppCore.shared.showPalette(mode: .launcher) }
            Button("Clipboard History") { AppCore.shared.showClipboard() }
            Button("My Schedule") {
                AppCore.shared.showPalette(mode: .calendar)
                Task { await AppCore.shared.calendarStore.requestAccessAndRefresh() }
            }
            Divider()
            Button("Settings...") { AppCore.shared.showSettings() }
                .keyboardShortcut(",")
            Divider()
            Button("Quit \(appName)") { NSApp.terminate(nil) }
                .keyboardShortcut("q")
        }
    }
}
