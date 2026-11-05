# Continuous probe bandwidth investigation — 2026-11-05

User constraints: preserve exact appearance, continuous live download/upload capacity measurement and freshness; substantially reduce interference with Wi-Fi throughput. No measurement-mode substitution authorized for this investigation.

Applied systematic-debugging: reproduce and trace before changes; compare alternatives; test the competing-traffic hypothesis by briefly unloading and restoring only the exact probe LaunchAgent.

## Live reproduction

Five-second en0 interface-counter samples, same session:

| Probe state | Download Mbps | Upload Mbps |
| --- | ---: | ---: |
| Running | 431.66 | 43.35 |
| Unloaded (after two-second settling) | 0.38 | 0.18 |
| Restored (after three-second settling) | 279.45 | 45.89 |

These counters include all en0 traffic. The sharp on/off/on change supports the probe as the dominant traffic source. Different running samples are not controlled estimates of total capacity. This establishes interference potential, not the exact amount of throughput lost to a particular application, nor a reduction in negotiated Wi-Fi PHY rate. No router configuration was changed.

## Code trace

Installed agent executes `~/.local/bin/speedtest-live-probe run`. Matching local source inspected at `~/.local/share/speedtest-menubar/liveprobe/main.go`:

- Eight download workers, four upload workers; unlimited continuous parallel requests.
- Download requests repeatedly fetch 100 MB; each upload worker allocates a 25 MB payload.
- Every 200 ms, cumulative counters feed a 500 ms rolling rate window; the measuring gate is forced open every tick.
- Upload counters advance when the HTTP client reads the request body, rather than when remote receipt is acknowledged; buffering can distort short-window upload readings.
- `retainLiveRate` retains prior positive values when no bytes advance. A fresh JSON timestamp does not by itself prove a fresh speed measurement.

Reducing worker count or allocations may improve resource use or fairness but cannot guarantee the same throughput measurement with sharply lower transferred bytes. Background scheduling or traffic prioritization can yield to applications, but then observed test throughput is affected. No such change is presented as satisfying all constraints.

## Research

- IETF RFC 5136 distinguishes capacity, available capacity and bulk-transfer capacity: https://www.rfc-editor.org/rfc/rfc5136.html
- M-Lab NDT measures bulk transport performance by transferring traffic; TCP statistics supplement the test: https://www.measurementlab.net/tests/ndt/ and https://www.measurementlab.net/tests/ndt/ndt7/
- CAIDA comparison of sparse packet-pair/train bandwidth estimators documents different metrics, timing sensitivities and measurement limitations: https://www.caida.org/catalog/papers/2005_pam_bwest/pam-bwest.pdf
- CoreWLAN transmitRate reports the Wi-Fi interface transmit rate, not end-to-end Internet download/upload capacity: https://developer.apple.com/documentation/corewlan/cwinterface/transmitrate()

No validated replacement found that preserves all requested properties. Sparse estimates, shorter tests, or opportunistic inference could preserve the UI but change certainty, measurement semantics or temporal coverage. Do not fake freshness through animation or retained values.

## Final state

Continuous probe restored under existing explicit opt-in. App appearance, source and measurement cadence unchanged. No implementation deployed because a compatible fix was not established. The exact requirements remain unresolved; a lower-impact design requires agreement on a measurement tradeoff.
