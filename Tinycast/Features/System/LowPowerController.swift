import Foundation
import AppKit

/// Owns the Low Power Mode toggle. macOS exposes a *read-only* `ProcessInfo` API; there is no
/// public way to flip it, so the controller runs `/usr/bin/pmset -a lowpowermode N` via
/// `osascript … with administrator privileges` — the standard GUI admin-password gate, prompted
/// once per toggle. No root helper, no stored credentials; the system holds the state.
/// `isEnabled` mirrors the live system state via `NSProcessInfoPowerStateDidChange`.
///
/// ponytail: LPM has no effect on AC power, but we honour the user's explicit choice regardless —
/// the system ignores the setting on AC; blocking it here would just be a second bug.
@MainActor
final class LowPowerController: ObservableObject {
    /// Live system Low Power Mode state, kept fresh by `NSProcessInfoPowerStateDidChange`.
    @Published private(set) var isEnabled = ProcessInfo.processInfo.isLowPowerModeEnabled

    private var observer: NSObjectProtocol?

    init() {}

    /// AppCore wiring: subscribe to power-state changes so `isEnabled` stays in sync even when the
    /// user flips LPM in System Settings or unplugs the charger.
    func start() {
        let center = NotificationCenter.default
        observer = center.addObserver(forName: .NSProcessInfoPowerStateDidChange, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.refresh() }
        }
        refresh()
    }

    /// AppCore shutdown: release the power-state observer. (No `deinit` touches `observer` — Swift 6
    /// forbids accessing a non-Sendable stored property from a nonisolated `deinit`.)
    func stop() {
        if let observer {
            NotificationCenter.default.removeObserver(observer)
            self.observer = nil
        }
    }

    /// Re-reads the authoritative system state.
    func refresh() {
        isEnabled = ProcessInfo.processInfo.isLowPowerModeEnabled
    }

    /// Flips Low Power Mode. Spawns `osascript` asking macOS to run `pmset` with admin privileges;
    /// the system presents the password sheet. On a zero-exit completion the published state is
    /// re-read (the change is synchronous from pmset's perspective). Cancellation/Error is surfaced
    /// only via console — there's nothing interactive to recover to.
    func toggle() async {
        let target = isEnabled ? "0" : "1"
        let script = "do shell script \"/usr/bin/pmset -a lowpowermode \(target)\" with administrator privileges"
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        proc.arguments = ["-e", script]
        do {
            try proc.run()
            proc.waitUntilExit()
            guard proc.terminationStatus == 0 else { return }
            refresh()
        } catch {
            // User cancelled the auth sheet or osascript itself failed to launch — no state change.
            print("LowPowerController: osascript failed: \(error)")
        }
    }
}
