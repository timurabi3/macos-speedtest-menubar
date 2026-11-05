# 🏃 HANDOFF — Speedtest menu bar widget: root-caused the "disappears forever" bug, shipped v3 as a real app

> Any agent (Claude Code / OpenCode / Hermes / Antigravity) reads this to continue where the last one stopped.

| | |
|---|---|
| **Status** | done — widget visible, crash-recovery verified |
| **Last agent** | claude-code (Fable 5) |
| **Updated** | 2026-07-19 |

## 🎯 Goal
Keep Timur's macOS Speedtest menu-bar widget polished, compact, visible, and live — permanently.

## 🔥 ROOT CAUSE (2026-07-19, verified live)
macOS 26 menu bar management (Control Center/SystemUIServer era) had **blacklisted the
bundle identity `com.timur.speedtestmenubar`** — most likely persisted when the item was
Cmd-dragged off the bar (~2026-07-16, see `MenuBarCustomizationState.RemovedControl=true`
in `com.apple.controlcenter`). Result: every status item that bundle created was silently
suppressed — process alive, event loop fine, renders running, but **zero windows** and
nothing in the bar. Neither defaults keys (`NSStatusItem Visible*`), ControlCenter restart,
SystemUIServer flag deletion, launch method (launchd vs. manual vs. `open`) changed it.
**Proof chain:** unbundled swift script + same autosaveName → visible; same app binary
with fresh bundle id `com.timur.speedtest3` → instantly visible. → Fix: new bundle id.

Secondary bugs fixed in the same pass (v2 code, `~/.local/share/speedtest-menubar/SpeedtestMenubarApp/`):
1. **exit(0) self-destruct**: watchdog exited 0, but LaunchAgent has `KeepAlive.SuccessfulExit=false`
   → launchd never restarted it ("gone forever"). v3 exits **1** (Crashed=true → restart).
2. **Dead-item detection hole**: `ensureVisible` only re-registered when `button == nil`;
   after sleep/wake the button stays non-nil with a dead backing window. v3 checks
   `windowNumber` + `occlusionState` (3-strike rule to tolerate fullscreen menu-bar hiding).
3. **No autosaveName** (v2 design) meant anonymous `Item-N` names; v3 restores
   `SpeedtestMenuBarStatusItem` and force-writes its `Visible`/`VisibleCC` defaults true
   on every registration, so a future drag-off can't stick.
4. CGWindowList is **useless** as a liveness signal on macOS 26 — status-item windows are
   composited out-of-process and never appear in the owner's window list. Don't reuse it.

## ✅ Current deployed state (all verified by screenshot + kill-test)
- **Canonical source:** `39_macOS_Speedtest_Menu_Bar/SpeedtestMenuBarApp/` (SwiftPM, this repo).
  Old `~/.local/share/speedtest-menubar/` is SUPERSEDED (left in place, do not build from it).
- **App:** `~/Applications/SpeedtestMenuBar.app`, bundle id **`com.timur.speedtest3`**, ad-hoc signed.
- **LaunchAgent:** `~/Library/LaunchAgents/com.timur.speedtestmenubar.plist` (label unchanged),
  execs the binary directly, `KeepAlive {SuccessfulExit=false, Crashed=true}`, RunAtLoad, Throttle 2s.
- **Probe:** `com.timur.speedtestliveprobe` LaunchAgent unchanged, feeds
  `~/Library/Caches/speedtest-menubar/latest.json` every ~1s.
- **Build/deploy:** `SpeedtestMenuBarApp/Scripts/install.sh` (build → bundle → sign → install → bootstrap → verify).
- **Verified:** widget visible in menu bar (screenshots), `kill -9` → launchd restarted new PID
  and item came back within seconds.

## ⏭️ Next steps (optional)
- Watch one full sleep/wake + display-plug cycle in the wild; the occlusion watchdog should
  self-heal within ~30 s. Logs: `~/Library/Caches/speedtest-menubar/native-app.err.log`.
- If macOS ever blacklists `com.timur.speedtest3` the same way (another drag-off), bump the
  bundle id in `version.env` and rerun `Scripts/install.sh` — 30-second fix.

## ⚠️ Watch out
- Menu "Quit" exits 0 on purpose → stays quit until next login or manual `launchctl kickstart`.
- Do NOT reintroduce the CGWindowList "windowServerConfirmsItem" check (false-dead every tick).
- Legacy defaults domain `com.timur.speedtestmenubar` still exists; harmless, don't reuse the id.

## 2026-11-05 — passive network activity and recovery

The continuous probe was deliberately disabled by `com.timur.network-probe-guard` after saturating the connection; do not enable it merely to clear stale readings. The app now samples local `en*` interface counters without generating traffic and labels the values as network activity, not capacity. It provides Restart App, Restart Probe (reports failure if the disabled/unloaded service cannot be started), and Reset Peaks. Probe auto-kickstarts were removed. An intentional continuous-probe opt-in and its bandwidth impact are documented in `../00_Network_Topology/NETWORK_SPEED_2026-11-05.md`.

Deployed to `~/Applications/SpeedtestMenuBar.app`, with the previous bundle preserved as `~/Applications/SpeedtestMenuBar.before-passive-20261105.app`. Release build and code signature passed; accessibility inspection showed changing values; menu Restart App produced a new launchd PID; Reset Peaks and the failed-probe alert were exercised. The probe remains disabled. Remote `origin/main` and local main have unrelated histories; do not force-push or merge them without reviewing the separate public project history.

## 2026-11-05 — continuous speed tests restored by explicit request

Timur explicitly chose continuous connection-speed testing even while idle after the passive traffic display showed near-zero readings. Restored the original live probe display, with Restart Probe, Restart App and Reset Peaks controls. The guard opt-in marker `~/.config/network-health-guard/allow-continuous-probe` was created, and `com.timur.speedtestliveprobe` was enabled and loaded. This intentionally generates substantial continuous network traffic. The earlier passive-only section above is superseded. Automatic stale recovery is throttled to once per 30 seconds; manual restart enables and bootstraps the agent if necessary.

Release build, signing, real menu actions, fresh probe readings, and running launchd services were checked. The guard script was run with the marker and left the probe enabled. Local and remote main remain unrelated histories.

## 2026-11-05 — continuous bandwidth investigation

User requests identical appearance and equally fresh accurate live tests with substantially less bandwidth interference. On/off/on five-second en0 samples: 431.66/43.35, 0.38/0.18, 279.45/45.89 Mbps down/up. Probe restored. Code and research findings in `docs/investigations/2026-11-05-continuous-probe-bandwidth.md`. No compatible implementation found; UI and probe code unchanged. Do not equate PHY link rate, available capacity estimates and measured bulk throughput. Requires agreement on a measurement tradeoff before substituting a lower-impact mechanism.
