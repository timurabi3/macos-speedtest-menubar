<p align="center">
  <img src="assets/banner.svg" alt="SpeedBar — live network speed in the macOS menu bar" width="100%">
</p>

# SpeedBar

Live download and upload speeds in your Mac’s menu bar, with sparklines and session peaks. Open the dashboard from the Dock, Spotlight, or **Open SpeedBar** in the menu bar.

**[Download SpeedBar for macOS](https://github.com/timurabi3/macos-speedtest-menubar/releases/latest/download/SpeedBar.dmg)** · [Release notes and checksum](https://github.com/timurabi3/macos-speedtest-menubar/releases/latest)

One universal app for Apple Silicon and Intel Macs running macOS 14 or later.

## Install

1. Open `SpeedBar.dmg` and drag **SpeedBar** onto **Applications**.
2. Eject the disk image. Press **⌘ Space**, type **SpeedBar**, and press Return.
3. Click **Start Continuous Test** to begin. To pin the app, Control-click its Dock icon and choose **Options → Keep in Dock**.

The current download is ad-hoc signed and has no Apple notarization. macOS may block the first launch. After trying to open SpeedBar, go to **System Settings → Privacy & Security → Open Anyway** if offered. See [Apple’s instructions](https://support.apple.com/en-us/102445).

If upgrading from a release that installed background agents, stop them once so you don't run two probes:

```bash
for label in com.timur.speedtestmenubar com.timur.speedtestliveprobe; do
  launchctl disable "gui/$(id -u)/$label"
  launchctl bootout "gui/$(id -u)/$label" 2>/dev/null || true
done
```

## Use SpeedBar

<img src="media/demo.gif" alt="Green download and red upload figures and sparklines updating in the menu bar" width="234">

Green is download; red is upload. SpeedBar generates test traffic continuously while enabled and updates the display about five times per second. Continuous testing uses bandwidth even when you're not browsing, and can compete with other activity on the same connection.

The dashboard shows current rates and session peaks in Mbps. Close the window to leave the menu bar running, click the Dock icon to reopen it, or choose **Pause Test** to stop traffic. **Quit SpeedBar** stops the app and its bundled probe. The app remembers your measurement choice for the next launch. No separate helper installation is required.

## Build from source

Use macOS 14+, the Xcode command-line tools with Swift 5.9+, and Go 1.22+.

```bash
go -C LiveProbe test ./...
SpeedtestMenuBarApp/Scripts/package_app.sh
```

The resulting universal app is at `SpeedtestMenuBarApp/build/SpeedBar.app`. To build and install to `~/Applications` in one step, run `./install.sh`.

For the styled disk image, also install [uv](https://docs.astral.sh/uv/), then run `SpeedtestMenuBarApp/Scripts/package_dmg.sh`. It writes `SpeedBar.dmg` and `SpeedBar.dmg.sha256` to the same build directory. For a notarized build, provide a Developer ID Application identity via `SPEEDBAR_SIGN_IDENTITY` and an existing `notarytool` keychain profile via `SPEEDBAR_NOTARY_PROFILE`.

The app launches the bundled Go probe as a child process and reads a private, per-session JSON file. The probe uses a rolling 500 ms window and updates that file every 200 ms. The probe stops when its input pipe closes, including when the app is force quit. The default endpoints are CacheFly for download and Cloudflare for upload; the process environment can override them with `SPEEDTEST_LIVE_DOWNLOAD_URL` and `SPEEDTEST_LIVE_UPLOAD_URL`.

All rights reserved.
