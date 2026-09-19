import Foundation

/// The small state machine used by the physical Space swipe event tap.
struct InstantSpaceSwipe: Sendable {
    enum Phase: Equatable, Sendable {
        case began
        case changed
        case ended
        case cancelled
        case other

        init(rawValue: Int64) {
            switch rawValue {
            case 1: self = .began
            case 2: self = .changed
            case 4: self = .ended
            case 8: self = .cancelled
            default: self = .other
            }
        }
    }

    enum Decision: Equatable, Sendable {
        case pass
        case suppress
        case switchTo(SpaceDirection)
    }

    private(set) var tracking = false
    private var fired = false

    mutating func reset() {
        tracking = false
        fired = false
    }

    mutating func handle(
        phase: Phase, progress: Double? = nil, velocity: Double? = nil
    ) -> Decision {
        switch phase {
        case .began:
            tracking = true
            fired = false
            return .suppress
        case .changed:
            guard tracking else { return .pass }
            if !fired, let progress, progress.isFinite, progress != 0 {
                fired = true
                return .switchTo(progress > 0 ? .next : .previous)
            }
            return .suppress
        case .ended:
            guard tracking else { return .pass }
            defer { reset() }
            if !fired, let velocity, velocity.isFinite, velocity != 0 {
                fired = true
                return .switchTo(velocity > 0 ? .next : .previous)
            }
            return .suppress
        case .cancelled:
            guard tracking else { return .pass }
            reset()
            return .suppress
        case .other:
            return tracking ? .suppress : .pass
        }
    }
}
