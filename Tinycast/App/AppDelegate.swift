import AppKit

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        AppCore.shared.start()
    }

    func applicationWillTerminate(_ notification: Notification) {
        // Tear down owned child processes + menu-bar artifacts first (terminate the caffeinate child before
        // removing the status items, so the coffee indicator never flashes a stale asserting state), then hand
        // the Hyper Key back: that HID-level caps remap outlives the process. Order matters across both.
        AppCore.shared.prepareForTermination()
        // The Hyper Key's HID-level caps remap outlives the process; give the key back.
        AppCore.shared.hyperKeyTap.prepareForTermination()
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        AppCore.shared.handleReopen()
        return true
    }
}
