import Foundation

/// Lazily-sourced current mic state + persisted last nonzero restore level (with a stable 100% default), with all `osascript` execution pushed off the main actor.
///
/// Reads/writes the system input volume via AppleScript against `System Events`/coreaudiod's `set volume` / `input volume`.
/// All `Process` invocations run on a detached utility task and return plain `Sendable` values across the actor boundary,
/// matching the house rule that raw process I/O never touches the main actor.
@MainActor
final class MicrophoneController: ObservableObject {
    private let defaults = UserDefaults.standard

    private enum Key {
        static let lastNonZero = "microphoneInputLevel"        // last persisted nonzero level, 1...100
    }

    /// Unmute-restore fallback when the user has never set a nonzero level. Stable 100% (full input gain) — never captured from the live system.
    static let defaultLevel = 100

    /// Current input volume 0...100. `setLevel` and `refresh` mutate this; views/menu items bind to it.
    @Published private(set) var inputLevel: Int = 0

    /// True iff `inputLevel == 0`. Cached alongside `inputLevel` so status items can bind a Bool without re-deriving.
    @Published private(set) var isMuted: Bool = true
    /// Last nonzero level the user explicitly set, so unmute restores it. Persists across launches.
    /// Bound by the Set Microphone Level palette view and status-item menu checkmark.
    @Published private(set) var lastNonZeroLevel: Int

    init() {
        // 0 (unset) reads as muted-default; a stored nonzero becomes the restore target.
        let storedNonZero = defaults.integer(forKey: Key.lastNonZero)
        lastNonZeroLevel = (1...100).contains(storedNonZero) ? storedNonZero : 0
    }

    // MARK: - Read

    /// Reads the current system input level off-main and hydrates `inputLevel`/`isMuted` and the persisted `lastNonZeroLevel`.
    func refresh() async {
        guard let level = await readSystemInputLevel() else { return }
        inputLevel = level
        isMuted = level == 0
        if level > 0 {
            lastNonZeroLevel = level
            defaults.set(level, forKey: Key.lastNonZero)
        }
    }

    // MARK: - Write

    /// Sets the input volume to `level` (clamped to 0...100). Persists `lastNonZero` and updates `inputLevel`/`isMuted`.
    func setLevel(_ level: Int) async {
        let clamped = max(0, min(100, level))
        guard await writeSystemInputLevel(clamped) else { return }
        inputLevel = clamped
        isMuted = clamped == 0
        if clamped > 0 {
            lastNonZeroLevel = clamped
            defaults.set(clamped, forKey: Key.lastNonZero)
        }
    }

    /// Flips between muted (0) and the most recent nonzero level (`lastNonZero`, falling back to the stable `defaultLevel`).
    func toggleMuted() async {
        if isMuted {
            let target = lastNonZeroLevel > 0 ? lastNonZeroLevel : Self.defaultLevel
            await setLevel(target)
        } else {
            await setLevel(0)
        }
    }

    // MARK: - Process I/O (off-main)

    /// Plain bridging result of an osascript read; crossing the actor boundary as a value, never a Process.
    private struct ScriptResult: Sendable {
        let stdout: String
        let stderr: String
        let status: Int32
    }

    /// Current system input volume as reported by AppleScript, or `nil` on any failure (no permission, missing audio device, bad output).
    private func readSystemInputLevel() async -> Int? {
        let result = await runAppleScript("input volume of (get volume settings)")
        guard result.status == 0,
            let level = Int(result.stdout.trimmingCharacters(in: .whitespacesAndNewlines)),
            (0...100).contains(level)
        else { return nil }
        return level
    }

    /// Writes the input volume via `set volume input volume N`, returning whether the script exited 0.
    private func writeSystemInputLevel(_ level: Int) async -> Bool {
        let result = await runAppleScript("set volume input volume \(level)")
        return result.status == 0
    }

    /// Runs `/usr/bin/osascript -e <script>` on a detached utility task. Bridges the raw stdout/stderr/status back as a `Sendable`.
    private func runAppleScript(_ source: String) async -> ScriptResult {
        await Task.detached(priority: .utility) {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
            process.arguments = ["-e", source]
            let outPipe = Pipe()
            let errPipe = Pipe()
            process.standardOutput = outPipe
            process.standardError = errPipe
            do {
                try process.run()
            } catch {
                return ScriptResult(stdout: "", stderr: String(describing: error), status: -1)
            }
            let outData = outPipe.fileHandleForReading.readDataToEndOfFile()
            let errData = errPipe.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            // Decode on the off-main task — never cross the actor boundary with raw bytes or the Process handle.
            return ScriptResult(
                stdout: String(data: outData, encoding: .utf8) ?? "",
                stderr: String(data: errData, encoding: .utf8) ?? "",
                status: process.terminationStatus)
        }.value
    }
}
