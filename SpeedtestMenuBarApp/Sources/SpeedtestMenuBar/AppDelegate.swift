import Cocoa

/// Application delegate — lightweight. All real work is in StatusBarController.
final class AppDelegate: NSObject, NSApplicationDelegate {

    private var controller: StatusBarController?
    private let probe = ProbeMonitor()

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        // Before anything reads latest.json: a freshly downloaded .app has no probe
        // installed, and the readout would sit at "--" forever. No-op once installed.
        ProbeInstaller.ensureInstalled()
        controller = StatusBarController(probe: probe)
        controller?.start()
    }

    func applicationWillTerminate(_ notification: Notification) {
        controller?.stop()
        controller = nil
    }

    /// If the user launches the .app again while it's already running,
    /// ensure the status item is visible.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        controller?.ensureVisible()
        return true
    }

    /// Catch-all: if the app gets a didBecomeActive (e.g. from Cmd+Tab or
    /// screen unlock), verify the status item still exists.
    func applicationDidBecomeActive(_ notification: Notification) {
        controller?.ensureVisible()
    }
}
