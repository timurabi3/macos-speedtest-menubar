# Runbook - macOS Speedtest Menu Bar Widget

## Before Acting
- Read `PROJECT_CONTEXT.md`.
- Check `SOURCE_PATHS.md` and choose the authoritative source/runtime path.
- If live infrastructure is involved, verify hostname and service state first.
- If generated docs conflict with live logs or live source, live evidence wins.

## Useful Steps
- Find current source with rg 'SpeedtestMenuBar|LaunchAgent|Mbps|download|upload'.
- Verify by recording/screenshotting live changes if project resumes.

## Stop Conditions
- Stop if a command would print secrets.
- Stop if source path and deployed path disagree and you cannot determine the active runtime.
- Stop if the user says `ok stop all work`.
