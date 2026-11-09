import Cocoa
import SwiftUI

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var controller: StatusBarController?
    private var window: NSWindow?
    private let probe = ProbeMonitor()

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        let appMenu = NSMenu()
        let quit = NSMenuItem(title: "Quit SpeedBar", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        appMenu.addItem(quit)
        let menu = NSMenu()
        let appMenuItem = NSMenuItem()
        appMenuItem.submenu = appMenu
        menu.addItem(appMenuItem)
        NSApp.mainMenu = menu

        controller = StatusBarController(probe: probe) { [weak self] in self?.showWindow() }
        controller?.start()
        showWindow()
    }

    private func showWindow() {
        if window == nil {
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 460, height: 315),
                                  styleMask: [.titled, .closable, .miniaturizable],
                                  backing: .buffered, defer: false)
            window.title = "SpeedBar"
            window.isReleasedWhenClosed = false
            window.contentView = NSHostingView(rootView: Dashboard(probe: probe))
            window.center()
            self.window = window
        }
        NSApp.activate(ignoringOtherApps: true)
        window?.deminiaturize(nil)
        window?.makeKeyAndOrderFront(nil)
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        controller?.ensureVisible()
        showWindow()
        return false
    }

    func applicationWillTerminate(_ notification: Notification) {
        controller?.stop()
        probe.stop()
    }
}

private struct Dashboard: View {
    @ObservedObject var probe: ProbeMonitor

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(spacing: 11) {
                Image(systemName: "speedometer")
                    .font(.system(size: 27, weight: .medium))
                    .foregroundStyle(Color.accentColor)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 3) {
                    Text("SpeedBar").font(.title2.bold())
                    Text(probe.status).font(.subheadline).foregroundStyle(.secondary)
                }
            }
            HStack(spacing: 12) {
                metric("Download", icon: "arrow.down", color: .green,
                       rate: probe.currentDownload, peak: probe.peakDownload)
                metric("Upload", icon: "arrow.up", color: .red,
                       rate: probe.currentUpload, peak: probe.peakUpload)
            }
            Text("Continuous testing uses your internet bandwidth while enabled. Closing this window keeps SpeedBar in the menu bar.")
                .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            HStack {
                Button(probe.enabled ? "Pause Test" : "Start Continuous Test") { probe.toggle() }
                    .buttonStyle(.borderedProminent)
                if probe.enabled {
                    Button("Reset Peaks") { probe.resetPeaks() }.disabled(probe.status != "Measuring")
                }
            }
        }
        .padding(24)
        .frame(width: 460, height: 315, alignment: .topLeading)
    }

    private func metric(_ name: String, icon: String, color: Color, rate: Double?, peak: Double?) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Label(name, systemImage: icon).font(.headline).foregroundStyle(color)
            HStack(alignment: .firstTextBaseline, spacing: 5) {
                Text(Format.mbps(rate)).font(.system(size: 29, weight: .semibold, design: .rounded))
                    .monospacedDigit()
                Text("Mbps").foregroundStyle(.secondary)
            }
            Text("Peak: \(Format.mbps(peak)) Mbps").font(.caption).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(13)
        .background(.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 12))
    }
}
