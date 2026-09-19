import AppKit
import Synchronization

private final class InstantSpaceSwipeCallbackState: Sendable {
    private struct State: Sendable {
        var swipe = InstantSpaceSwipe()
        var active = false
    }

    private let state = Mutex(State())

    func start() {
        state.withLock {
            $0.active = true
            $0.swipe.reset()
        }
    }

    func stop() {
        state.withLock {
            $0.active = false
            $0.swipe.reset()
        }
    }

    func reset() {
        state.withLock { $0.swipe.reset() }
    }

    func isActive() -> Bool {
        state.withLock { $0.active }
    }
    func isTracking() -> Bool {
        state.withLock { $0.active && $0.swipe.tracking }
    }

    func handle(
        phase: InstantSpaceSwipe.Phase, progress: Double?, velocity: Double?
    ) -> InstantSpaceSwipe.Decision {
        state.withLock {
            guard $0.active else { return .pass }
            return $0.swipe.handle(phase: phase, progress: progress, velocity: velocity)
        }
    }
}

private func instantSpaceSwipeEventTapCallback(
    proxy: CGEventTapProxy, type: CGEventType, event: CGEvent,
    userInfo: UnsafeMutableRawPointer?
) -> Unmanaged<CGEvent>? {
    guard let userInfo else { return Unmanaged.passUnretained(event) }
    let monitor = Unmanaged<InstantSpaceSwipeMonitor>.fromOpaque(userInfo).takeUnretainedValue()

    if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
        monitor.callbackState.reset()
        Task { @MainActor [weak monitor] in monitor?.tapWasDisabled() }
        return Unmanaged.passUnretained(event)
    }

    let eventType = event.getIntegerValueField(CGEventField(rawValue: 55)!)
    let isDockSwipe = eventType == 30
    let isCompanionGesture = eventType == 29
    guard isDockSwipe || isCompanionGesture else { return Unmanaged.passUnretained(event) }

    // Source PID zero identifies physical HID input.
    guard event.getIntegerValueField(.eventSourceUnixProcessID) == 0 else {
        return Unmanaged.passUnretained(event)
    }

    if isCompanionGesture {
        return monitor.callbackState.isTracking()
            ? nil
            : Unmanaged.passUnretained(event)
    }

    guard event.getIntegerValueField(CGEventField(rawValue: 110)!) == 23,
        event.getIntegerValueField(CGEventField(rawValue: 123)!) == 1
    else { return Unmanaged.passUnretained(event) }
    let phase = InstantSpaceSwipe.Phase(
        rawValue: event.getIntegerValueField(CGEventField(rawValue: 132)!))
    let progress = event.getDoubleValueField(CGEventField(rawValue: 124)!)
    let velocity = event.getDoubleValueField(CGEventField(rawValue: 129)!)
    switch monitor.callbackState.handle(phase: phase, progress: progress, velocity: velocity) {
    case .pass:
        return Unmanaged.passUnretained(event)
    case .suppress:
        return nil
    case .switchTo(let direction):
        monitor.schedule(direction)
        return nil
    }
}

/// Intercepts the physical horizontal trackpad Space gesture without showing a picker.
@MainActor
final class InstantSpaceSwipeMonitor {
    private static let eventMask: CGEventMask = (1 << 29) | (1 << 30)

    private let spaceSwitcher: SpaceSwitcher
    fileprivate nonisolated let callbackState = InstantSpaceSwipeCallbackState()
    private var tapPort: CFMachPort?
    private var runLoopSource: CFRunLoopSource?

    init(spaceSwitcher: SpaceSwitcher) {
        self.spaceSwitcher = spaceSwitcher
    }

    isolated deinit {
        stop()
    }

    func start() -> Bool {
        guard tapPort == nil else { return true }
        // This feature never prompts; SpaceSwitcher still needs the same grant to post.
        guard Permissions.isAccessibilityTrusted(),
            let port = CGEvent.tapCreate(
                tap: .cgSessionEventTap,
                place: .headInsertEventTap,
                options: .defaultTap,
                eventsOfInterest: Self.eventMask,
                callback: instantSpaceSwipeEventTapCallback,
                userInfo: Unmanaged.passUnretained(self).toOpaque())
        else {
            callbackState.stop()
            return false
        }
        guard let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, port, 0) else {
            CFMachPortInvalidate(port)
            callbackState.stop()
            return false
        }
        tapPort = port
        runLoopSource = source
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        callbackState.start()
        CGEvent.tapEnable(tap: port, enable: true)
        return true
    }

    func stop() {
        callbackState.stop()
        if let runLoopSource {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), runLoopSource, .commonModes)
            self.runLoopSource = nil
        }
        if let tapPort {
            CGEvent.tapEnable(tap: tapPort, enable: false)
            CFMachPortInvalidate(tapPort)
            self.tapPort = nil
        }
    }

    fileprivate func tapWasDisabled() {
        callbackState.reset()
        if let tapPort { CGEvent.tapEnable(tap: tapPort, enable: true) }
    }

    nonisolated func schedule(_ direction: SpaceDirection) {
        Task { @MainActor [weak self] in
            guard let self, self.callbackState.isActive() else { return }
            self.spaceSwitcher.perform(direction)
        }
    }
}
