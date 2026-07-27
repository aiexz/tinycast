import Foundation
import AppKit

/// Owns the exact lifecycle of `caffeinate` child processes, supporting indefinite, duration, until-date, and while-app sessions.
/// Never shells out or uses `killall` — holds and terminates only the `Process` instances it spawned.
@MainActor
final class CaffeinationController: ObservableObject {
    private let defaults = UserDefaults.standard

    private enum Key {
        /// Persisted Raycast Coffee package preferences — the default `-d`/`-i`/`-m` flag set used when a command
        /// (For / Until / While) is invoked without an explicit `flags:` argument. Mirrors the source
        /// preference checks "prevent display sleep" / "prevent idle sleep" / "prevent disk sleep".
        static let preferenceFlags = "caffeinationPreferenceFlags"
    }

    /// Configuration for a caffeination session; maps to `/usr/bin/caffeinate` arguments.
    struct Flags: Sendable, Equatable, Codable {
        var displaySleep: Bool
        var idleSleep: Bool
        var diskIdle: Bool

        init(displaySleep: Bool = true, idleSleep: Bool = true, diskIdle: Bool = true) {
            self.displaySleep = displaySleep
            self.idleSleep = idleSleep
            self.diskIdle = diskIdle
        }
    }

    static let defaultFlags = Flags()

    enum CaffeinationTarget: Equatable, Sendable {
        case bundleID(String)
        case pid(Int32)
    }

    enum Mode: Equatable, Sendable {
        case inactive
        case indefinite
        case duration(TimeInterval)
        case until(Date)
        case whileApp(CaffeinationTarget)
    }


    /// Exposed for UI state (e.g. icon highlighting, label naming). Only reflects ACTIVE state.
    @Published private(set) var mode: Mode = .inactive
    @Published private(set) var remaining: TimeInterval?
    /// Persisted Raycast Coffee package preference (the default flag set). Overridden only by an explicit `flags:` arg.
    /// Editable from General Settings; survives launches.
    @Published private(set) var preferenceFlags: Flags


    var isActive: Bool { mode != .inactive }

    /// Source-named alias for `isActive` (`IsRunning`): true whenever a `caffeinate` child is actively asserting.
    var isRunning: Bool { isActive }

    var remainingDescription: String? {
        guard let remaining else { return nil }
        let seconds = max(0, Int(remaining))
        let hours = seconds / 3600
        let minutes = (seconds % 3600) / 60
        let secs = seconds % 60
        if hours > 0 { return "\(hours)h \(minutes)m remaining" }
        if minutes > 0 { return "\(minutes)m \(secs)s remaining" }
        return "\(secs)s remaining"
    }


    private var activeProcess: Process?
    private var manualMode: Mode = .inactive
    private var expirationDate: Date?
    private var tickTimer: Timer?
    private var workspaceObservers: [NotificationToken] = []

    init() {
        // Persistent flags preference; falls back to the source-default full assertion when unset.
        if let data = defaults.data(forKey: Key.preferenceFlags), let decoded = try? JSONDecoder().decode(Flags.self, from: data) {
            preferenceFlags = decoded
        } else {
            preferenceFlags = Self.defaultFlags
        }
    }

    /// Updates the persisted coffee preference flags (the Raycast package default). Additive; the General Settings
    /// toggle calls this so existing/queued sessions continue with whatever flags they were launched under.
    func setPreferenceFlags(_ flags: Flags) {
        preferenceFlags = flags
        if let data = try? JSONEncoder().encode(flags) {
            defaults.set(data, forKey: Key.preferenceFlags)
        }
    }

    /// Resolves an optional caller-supplied flag set against the persisted preference. `prefFlags(nil)` ⇒ preference.
    private func resolveFlags(_ flags: Flags?) -> Flags { flags ?? preferenceFlags }

    /// AppCore wiring: kicks off the 1Hz evaluator and UI-tick timer.
    func start() {
        let timer = Timer(timeInterval: 1.0, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
        RunLoop.main.add(timer, forMode: .common)
        tickTimer = timer
    }

    /// AppCore shutdown: terminates the child and releases observers synchronously on app exit.
    func prepareForTermination() {
        tickTimer?.invalidate()
        tickTimer = nil
        terminateActiveProcess()
        workspaceObservers.removeAll()
    }

    // MARK: - Manual Control API

    func caffeinate() async {
        manualMode = .indefinite
        applyState()
    }

    func caffeinate(for duration: TimeInterval, flags: Flags? = nil) async {
        guard duration > 0 else { return }
        // Source-equivalent: a For-Duration session is `.duration(t)` (preset territory), not `.until(date)` —
        // this preserves preset recognition in the status menu (a `.duration(t)` row matches iff `t` is in the
        // preset set; `.until(date)` does not). `applyState` resolves the expiry from either variant.
        manualMode = .duration(duration)
        applyState(flags: resolveFlags(flags))
    }

    func caffeinate(until date: Date, flags: Flags? = nil) async {
        manualMode = .until(date)
        applyState(flags: resolveFlags(flags))
    }

    func caffeinateWhileApp(_ target: CaffeinationTarget, flags: Flags? = nil) async {
        manualMode = .whileApp(target)
        applyState(flags: resolveFlags(flags))
    }

    func decaffeinate() async {
        manualMode = .inactive
        applyState()
    }

    func toggle() async {
        if isActive {
            manualMode = .inactive
            applyState()
        } else {
            await caffeinate()
        }
    }

    // MARK: - Internal Lifecycle & Execution

    /// Unconditionally terminates the running `/usr/bin/caffeinate` child, clears its reference, and removes its workspace observers.
    private func terminateActiveProcess() {
        activeProcess?.terminate()
        activeProcess = nil
        workspaceObservers.removeAll()
    }

    /// Resolves manual assertion and executes the process replacement.
    private func applyState(flags: Flags = defaultFlags) {
        terminateActiveProcess()
        expirationDate = nil

        let effectiveMode: Mode
        let effectiveFlags: Flags
        let resolvedExpiration: Date?

        if manualMode != .inactive {
            effectiveMode = manualMode
            effectiveFlags = flags
            switch manualMode {
            case .duration(let duration): resolvedExpiration = Date().addingTimeInterval(duration)
            case .until(let date): resolvedExpiration = date
            default: resolvedExpiration = nil
            }
        } else {
            mode = .inactive
            remaining = nil
            return
        }

        expirationDate = resolvedExpiration
        var args = [String]()
        if effectiveFlags.displaySleep { args.append("-d") }
        if effectiveFlags.idleSleep { args.append("-i") }
        if effectiveFlags.diskIdle { args.append("-m") }

        if let expiration = resolvedExpiration {
            let duration = expiration.timeIntervalSince(Date())
            guard duration > 0 else {
                mode = .inactive
                remaining = nil
                manualMode = .inactive
                expirationDate = nil
                return
            }
            args += ["-t", String(max(1, Int(duration.rounded(.up))))]
        }

        // For while-app, find the PID now so `caffeinate -w` can watch it natively.
        var targetPID: Int32?
        if case .whileApp(let target) = effectiveMode {
            switch target {
            case .pid(let p): targetPID = p
            case .bundleID(let bID):
                let running = NSWorkspace.shared.runningApplications.first(where: { $0.bundleIdentifier == bID })
                if let p = running?.processIdentifier {
                    targetPID = p
                } else {
                    // App isn't running; immediate abort per contract (or wait for it, but standard is abort)
                    mode = .inactive
                    remaining = nil
                    manualMode = .inactive
                    return
                }
            }
            if let p = targetPID {
                args.append("-w")
                args.append(String(p))
            }
        }

        // 3. Launch Process
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/caffeinate")
        process.arguments = args

        do {
            try process.run()
            self.activeProcess = process
            self.mode = effectiveMode

            // 4. Set up exact lifecycle observer — if caffeinate dies natively (timeout or app exit), clean up.
            let pid = process.processIdentifier
            process.terminationHandler = { [weak self] _ in
                Task { @MainActor in
                    guard let self, self.activeProcess?.processIdentifier == pid else { return }
                    self.activeProcess = nil
                    self.workspaceObservers.removeAll()
                    self.mode = .inactive
                    self.remaining = nil
                    self.expirationDate = nil
                }
            }

            // Fallback workspace observer for .whileApp (in case native `-w` fails to terminate instantly)
            if case .whileApp(let target) = effectiveMode, case .bundleID(let targetBundle) = target {
                let center = NSWorkspace.shared.notificationCenter
                let token = center.addObserver(forName: NSWorkspace.didTerminateApplicationNotification, object: nil, queue: .main) { [weak self] notification in
                    guard let app = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication,
                          app.bundleIdentifier == targetBundle else { return }
                    MainActor.assumeIsolated {
                        if case .whileApp(let activeTarget) = self?.manualMode, case .bundleID(let activeBundle) = activeTarget, activeBundle == targetBundle {
                            Task {
                                await self?.decaffeinate()
                            }
                        }
                    }
                }
                self.workspaceObservers.append(NotificationToken(token, center: center))
            }
        } catch {
            print("CaffeinationController failed to launch caffeinate: \(error)")
            self.mode = .inactive
            self.remaining = nil
        }
    }

    /// 1Hz tick handling UI time remaining.
    private func tick() {
        switch mode {
        case .duration, .until:
            guard let expirationDate else { remaining = nil; return }
            remaining = max(0, expirationDate.timeIntervalSince(Date()))
        case .inactive, .indefinite, .whileApp:
            remaining = nil
        }
    }
}
