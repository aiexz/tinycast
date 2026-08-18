import AppKit
// `@preconcurrency` downgrades AX diagnostics: the attribute keys are constant C globals.
@preconcurrency import ApplicationServices

/// Reads text out of another app over Accessibility, always against a named process: the system-wide
/// focused element follows whichever window holds key, so it answers with ours while a panel is up.
enum AccessibilityText {
    /// Generous for a responsive app, short enough that a wedged one can't stall the main actor.
    private static let timeout: Float = 1

    static func focusedElement(in app: NSRunningApplication) -> AXUIElement? {
        let application = AXUIElementCreateApplication(app.processIdentifier)
        // Per element and never inherited, so the focused element needs its own against a hang.
        AXUIElementSetMessagingTimeout(application, timeout)
        var focusedValue: CFTypeRef?
        guard
            AXUIElementCopyAttributeValue(
                application,
                kAXFocusedUIElementAttribute as CFString,
                &focusedValue) == .success,
            let focusedValue,
            CFGetTypeID(focusedValue) == AXUIElementGetTypeID()
        else { return nil }

        let element = focusedValue as! AXUIElement
        AXUIElementSetMessagingTimeout(element, timeout)
        return element
    }

    static func selection(in app: NSRunningApplication) -> String? {
        guard let element = focusedElement(in: app) else { return nil }
        var value: CFTypeRef?
        guard
            AXUIElementCopyAttributeValue(
                element,
                kAXSelectedTextAttribute as CFString,
                &value) == .success
        else { return nil }
        return value as? String
    }
}
