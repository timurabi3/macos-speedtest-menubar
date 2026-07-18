# Open Tasks - macOS Speedtest Menu Bar Widget

## Known Open Items
- (none blocking) Widget deployed as v3 with bundle id com.timur.speedtest3; visible and crash-recovering as of 2026-07-19.
- Optional: observe first real sleep/wake cycle; occlusion watchdog should recover within ~30s (see HANDOFF.md).

## Verification Needed
- After any future "widget gone" report: check `pgrep -x SpeedtestMenuBar`, then
  `~/Library/Caches/speedtest-menubar/native-app.err.log`, then rebuild via
  `SpeedtestMenuBarApp/Scripts/install.sh`. If macOS blacklisted the bundle id again,
  bump BUNDLE_ID in `SpeedtestMenuBarApp/version.env` and reinstall.
