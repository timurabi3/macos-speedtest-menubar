package main

import (
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"net/http"
	"os"
	"os/signal"
	"path/filepath"
	"strconv"
	"strings"
	"sync/atomic"
	"syscall"
	"time"
)

const (
	defaultDownloadURL  = "https://cachefly.cachefly.net/100mb.test"
	defaultUploadURL    = "https://speed.cloudflare.com/__up"
	downloadWorkerCount = 8
	uploadWorkerCount   = 4
	stateRelPath        = "Library/Caches/speedtest-menubar/latest.json"
	pidRelPath          = "Library/Caches/speedtest-menubar/liveprobe.pid"
	logRelPath          = "Library/Caches/speedtest-menubar/liveprobe.log"
	controlRelPath      = "Library/Caches/speedtest-menubar/liveprobe-control.json"
	controlPause        = "pause"
	controlResume       = "resume"
	controlReset        = "reset"
	controlTest         = "test"
	sampleInterval      = 200 * time.Millisecond
	rollingWindow       = 500 * time.Millisecond

	// HYBRID measurement. Two different questions, answered two different ways:
	//
	//   "what am I using right now?"  -> passive: diff the OS interface byte
	//                                    counters. Costs nothing, always live.
	//   "how fast is this line?"      -> active: saturate the link briefly and
	//                                    measure. Costs exactly what it measures.
	//
	// The previous always-on design answered the second question continuously,
	// which meant permanently saturating the connection: measured at ~235 Mbps
	// down and ~44 Mbps up sustained, i.e. ~125 GB/hour or ~3 TB/day, plus the
	// same volume hammering CacheFly's and Cloudflare's free test endpoints from
	// a single IP. A 6s test every 30min is a 0.33% duty cycle -- about 10 GB/day
	// -- while passive sampling keeps the readout moving in between.
	passiveInterval    = 1 * time.Second
	activeTestInterval = 30 * time.Minute
	activeTestDuration = 6 * time.Second
	// TCP slow start and connection setup make the first moment of a burst
	// unrepresentative; ignore it when picking the peak.
	activeTestWarmup = 1500 * time.Millisecond

	// The traffic gate. Workers stay alive for the process lifetime but only
	// generate traffic while the gate is open, which is exactly the duration of a
	// capacity test.
	activePhaseMeasuring = int64(0)
	activePhaseIdle      = int64(1)
	// A session peak is only accepted once a comparable rate is seen on at least
	// this many consecutive samples, so a single transient TCP burst can't inflate
	// the displayed "Max" beyond a realistic sustained top speed.
	peakSustainSamples = 2
)

type State struct {
	Mode                    string   `json:"mode"`
	Status                  string   `json:"status"`
	Phase                   string   `json:"phase"`
	PID                     any      `json:"pid"`
	DownloadMbps            *float64 `json:"download_mbps"`
	UploadMbps              *float64 `json:"upload_mbps"`
	DownloadPeakMbps        *float64 `json:"download_peak_mbps"`
	UploadPeakMbps          *float64 `json:"upload_peak_mbps"`
	SessionDownloadPeakMbps *float64 `json:"session_download_peak_mbps"`
	SessionUploadPeakMbps   *float64 `json:"session_upload_peak_mbps"`
	// Capacity: what the last active test achieved. Distinct from
	// Download/UploadMbps, which are passive utilisation -- what is actually
	// flowing, usually near zero on an idle machine.
	CapacityDownloadMbps *float64 `json:"capacity_download_mbps"`
	CapacityUploadMbps   *float64 `json:"capacity_upload_mbps"`
	LastTestAt           int64    `json:"last_test_at"`
	NextTestAt           int64    `json:"next_test_at"`
	UpdatedAt            int64    `json:"updated_at"`
	StartedAt            int64    `json:"started_at"`
	Error                any      `json:"error"`
}

type controlCommand struct {
	Command   string `json:"command"`
	Timestamp int64  `json:"timestamp"`
}

type counters struct {
	download atomic.Int64
	upload   atomic.Int64
}

type sample struct {
	at       time.Time
	downByte int64
	upByte   int64
}

type rateWindow struct {
	span    time.Duration
	samples []sample
}

type countingReader struct {
	reader io.Reader
	count  *atomic.Int64
}

type countingReadCloser struct {
	io.ReadCloser
	count *atomic.Int64
}

func newRateWindow(span time.Duration) *rateWindow {
	return &rateWindow{span: span}
}

func (r *rateWindow) add(at time.Time, downBytes int64, upBytes int64) {
	r.samples = append(r.samples, sample{at: at, downByte: downBytes, upByte: upBytes})
	cutoff := at.Add(-r.span - 250*time.Millisecond)
	keep := 0
	for keep < len(r.samples) && r.samples[keep].at.Before(cutoff) {
		keep++
	}
	if keep > 0 {
		r.samples = append([]sample(nil), r.samples[keep:]...)
	}
}

func (r *rateWindow) rates(now time.Time) (float64, float64) {
	if len(r.samples) < 2 {
		return 0, 0
	}
	target := now.Add(-r.span)
	base := r.samples[0]
	for _, s := range r.samples {
		if !s.at.After(target) {
			base = s
		}
	}
	latest := r.samples[len(r.samples)-1]
	elapsed := latest.at.Sub(base.at)
	if elapsed <= 0 {
		return 0, 0
	}
	return mbpsFromBytes(latest.downByte-base.downByte, elapsed), mbpsFromBytes(latest.upByte-base.upByte, elapsed)
}

func mbpsFromBytes(byteCount int64, elapsed time.Duration) float64 {
	if elapsed <= 0 || byteCount <= 0 {
		return 0
	}
	value := (float64(byteCount) * 8) / elapsed.Seconds() / 1_000_000
	return float64(int(value*100+0.5)) / 100
}

func floatPtr(v float64) *float64 { return &v }

func main() {
	command := "run"
	if len(os.Args) > 1 {
		command = os.Args[1]
	}
	switch command {
	case "run":
		os.Exit(run())
	case "status":
		os.Exit(printStatus())
	case "reset":
		os.Exit(resetPeaks())
	case "pause":
		os.Exit(pauseProbe())
	case "resume":
		os.Exit(resumeProbe())
	case "test":
		os.Exit(requestCapacityTest())
	default:
		fmt.Fprintf(os.Stderr, "usage: %s [run|status|reset|pause|resume|test]\n", os.Args[0])
		os.Exit(2)
	}
}

func run() int {
	ctx, stop := signal.NotifyContext(context.Background(), syscall.SIGTERM, syscall.SIGINT)
	defer stop()
	statePath := homePath(stateRelPath)
	pidPath := homePath(pidRelPath)
	controlPath := homePath(controlRelPath)
	if err := os.MkdirAll(filepath.Dir(statePath), 0755); err != nil {
		fmt.Fprintln(os.Stderr, err)
		return 1
	}
	if err := os.WriteFile(pidPath, []byte(fmt.Sprintf("%d\n", os.Getpid())), 0644); err != nil {
		fmt.Fprintln(os.Stderr, err)
		return 1
	}
	defer os.Remove(pidPath)

	client := &http.Client{Timeout: 0}
	var c counters
	var activePhase atomic.Int64
	started := time.Now()
	// Start with the traffic gate CLOSED. The workers exist for the lifetime of
	// the process but only generate traffic during a capacity test.
	activePhase.Store(activePhaseIdle)
	downURL := downloadURL()
	upURL := uploadURL()
	for i := 0; i < downloadWorkerCount; i++ {
		go downloadWorker(ctx, client, downURL, &c, &activePhase)
	}
	for i := 0; i < uploadWorkerCount; i++ {
		go uploadWorker(ctx, client, upURL, &c, &activePhase)
	}

	var (
		sessionDownPeak float64
		sessionUpPeak   float64
		capacityDown    float64
		capacityUp      float64
		liveDown        float64
		liveUp          float64
		lastTestAt      time.Time
		paused          bool
	)
	lastControlTimestamp := started.UnixNano()

	prevIn, prevOut, err := interfaceTotals()
	if err != nil {
		logProbeError("counters", err)
	}
	prevSampledAt := started

	interval := testInterval()
	duration := testDuration()

	publish := func(now time.Time, status string, phase string, pid any, down float64, up float64) {
		var lastTest, nextTest int64
		if !lastTestAt.IsZero() {
			lastTest = lastTestAt.Unix()
			nextTest = lastTestAt.Add(interval).Unix()
		}
		_ = writeStateFile(statePath, State{
			Mode: "hybrid", Status: status, Phase: phase, PID: pid,
			DownloadMbps: floatPtr(down), UploadMbps: floatPtr(up),
			DownloadPeakMbps: floatPtr(capacityDown), UploadPeakMbps: floatPtr(capacityUp),
			SessionDownloadPeakMbps: floatPtr(sessionDownPeak), SessionUploadPeakMbps: floatPtr(sessionUpPeak),
			CapacityDownloadMbps: floatPtr(capacityDown), CapacityUploadMbps: floatPtr(capacityUp),
			LastTestAt: lastTest, NextTestAt: nextTest,
			UpdatedAt: now.Unix(), StartedAt: started.Unix(), Error: nil,
		})
	}

	ticker := time.NewTicker(passiveInterval)
	defer ticker.Stop()

	for {
		select {
		case <-ctx.Done():
			publish(time.Now(), "stopped", "stopped", nil, liveDown, liveUp)
			return 0
		case now := <-ticker.C:
			// Passive: diff the OS interface counters. This is what the link is
			// actually carrying, and it costs nothing to observe.
			if in, out, err := interfaceTotals(); err != nil {
				logProbeError("counters", err)
			} else {
				elapsed := now.Sub(prevSampledAt)
				liveDown = mbpsFromBytes(deltaBytes(in, prevIn), elapsed)
				liveUp = mbpsFromBytes(deltaBytes(out, prevOut), elapsed)
				prevIn, prevOut, prevSampledAt = in, out, now
			}

			testRequested := false
			command, hasCommand, err := pendingControlCommand(controlPath, lastControlTimestamp)
			if err != nil {
				logProbeError("control", err)
			}
			if hasCommand {
				lastControlTimestamp = command.Timestamp
				switch command.Command {
				case controlReset:
					resetSessionPeaks(&sessionDownPeak, &sessionUpPeak, capacityDown, capacityUp)
				case controlPause:
					paused = true
				case controlResume:
					paused = false
				case controlTest:
					testRequested = true
				}
				if err := clearControlFileIfSame(controlPath, command); err != nil {
					logProbeError("control", err)
				}
			}

			if paused {
				// Passive sampling continues while paused -- it generates no
				// traffic, so there is nothing to pause about it. What stops is
				// capacity testing.
				status, phase, pid := probeStatus(true, false, os.Getpid())
				publish(now, status, phase, pid, liveDown, liveUp)
				continue
			}

			if testRequested || lastTestAt.IsZero() || now.Sub(lastTestAt) >= interval {
				down, up := runCapacityTest(ctx, &c, &activePhase, duration, func(d float64, u float64) {
					status, phase, pid := probeStatus(false, true, os.Getpid())
					publish(time.Now(), status, phase, pid, d, u)
				})
				if ctx.Err() != nil {
					publish(time.Now(), "stopped", "stopped", nil, liveDown, liveUp)
					return 0
				}
				lastTestAt = time.Now()
				if down > 0 {
					capacityDown = down
				}
				if up > 0 {
					capacityUp = up
				}
				if capacityDown > sessionDownPeak {
					sessionDownPeak = capacityDown
				}
				if capacityUp > sessionUpPeak {
					sessionUpPeak = capacityUp
				}
				// The burst was our own traffic. Resync the passive baseline so the
				// next sample doesn't bill the user for the test we just ran.
				if in, out, err := interfaceTotals(); err == nil {
					prevIn, prevOut, prevSampledAt = in, out, time.Now()
				}
			}

			status, phase, pid := probeStatus(false, false, os.Getpid())
			publish(now, status, phase, pid, liveDown, liveUp)
		}
	}
}

// runCapacityTest opens the traffic gate, measures achievable throughput for
// activeTestDuration, then closes it again. Returns the sustained peak seen.
//
// It publishes on every inner tick. The burst lasts several seconds and the menu
// bar app treats a state file more than a few seconds old as a dead probe, so a
// silent test would trigger the very restart machinery that used to storm.
func runCapacityTest(ctx context.Context, c *counters, activePhase *atomic.Int64, duration time.Duration, publish func(down float64, up float64)) (float64, float64) {
	activePhase.Store(activePhaseMeasuring)
	defer activePhase.Store(activePhaseIdle)

	start := time.Now()
	window := newRateWindow(rollingWindow)
	window.add(start, c.download.Load(), c.upload.Load())

	downStreak := newPeakStreak()
	upStreak := newPeakStreak()
	var bestDown, bestUp float64

	deadline := start.Add(duration)
	warmupUntil := start.Add(activeTestWarmup)
	ticker := time.NewTicker(sampleInterval)
	defer ticker.Stop()

	for {
		select {
		case <-ctx.Done():
			return bestDown, bestUp
		case now := <-ticker.C:
			window.add(now, c.download.Load(), c.upload.Load())
			down, up := window.rates(now)
			publish(down, up)
			// Ignore the ramp: TCP slow start makes the first moment meaningless.
			if now.After(warmupUntil) {
				if adopt, ok := downStreak.accept(down, bestDown); ok {
					bestDown = adopt
				}
				if adopt, ok := upStreak.accept(up, bestUp); ok {
					bestUp = adopt
				}
			}
			if !now.Before(deadline) {
				return bestDown, bestUp
			}
		}
	}
}

func downloadWorker(ctx context.Context, client *http.Client, url string, c *counters, activePhase *atomic.Int64) {
	for ctx.Err() == nil {
		if activePhase.Load() != activePhaseMeasuring {
			if !sleepOrDone(ctx, 100*time.Millisecond) {
				return
			}
			continue
		}

		backoff := downloadOnce(ctx, client, url, c, activePhase)
		if backoff && !sleepOrDone(ctx, 500*time.Millisecond) {
			return
		}
	}
}

// downloadOnce runs a single download request under an idle-cancellable context.
// It returns true if the caller should back off before retrying (a real error),
// false for clean completion or an expected cancellation (shutdown / idle gate).
func downloadOnce(ctx context.Context, client *http.Client, url string, c *counters, activePhase *atomic.Int64) bool {
	// Child context cancelled the moment the idle gate trips, so a long 100MB
	// download aborts promptly at the end of a burst instead of spilling
	// traffic into the rest window.
	reqCtx, cancel := gateContext(ctx, activePhase)
	defer cancel()

	req, err := http.NewRequestWithContext(reqCtx, http.MethodGet, url, nil)
	if err != nil {
		logProbeError("download", err)
		return true
	}

	resp, err := client.Do(req)
	if err != nil {
		if reqCtx.Err() != nil {
			return false // shutdown or idle gate — expected
		}
		logProbeError("download", err)
		return true
	}
	defer resp.Body.Close()

	if resp.StatusCode >= 400 {
		_, _ = io.Copy(io.Discard, resp.Body)
		logProbeError("download", fmt.Errorf("HTTP %d from %s", resp.StatusCode, url))
		return true
	}

	counting := &countingReadCloser{ReadCloser: resp.Body, count: &c.download}
	if _, err := io.Copy(io.Discard, counting); err != nil {
		if reqCtx.Err() != nil {
			return false // cancelled by shutdown or idle gate — not a real error
		}
		logProbeError("download", err)
		return true
	}
	return false
}

func uploadWorker(ctx context.Context, client *http.Client, url string, c *counters, activePhase *atomic.Int64) {
	payload := bytes.Repeat([]byte{0}, 25_000_000)
	for ctx.Err() == nil {
		if activePhase.Load() != activePhaseMeasuring {
			if !sleepOrDone(ctx, 100*time.Millisecond) {
				return
			}
			continue
		}

		backoff := uploadOnce(ctx, client, url, payload, c, activePhase)
		if backoff && !sleepOrDone(ctx, 500*time.Millisecond) {
			return
		}
	}
}

// uploadOnce runs a single upload request under an idle-cancellable context.
// Return semantics match downloadOnce.
func uploadOnce(ctx context.Context, client *http.Client, url string, payload []byte, c *counters, activePhase *atomic.Int64) bool {
	reqCtx, cancel := gateContext(ctx, activePhase)
	defer cancel()

	body := &countingReader{reader: bytes.NewReader(payload), count: &c.upload}
	req, err := http.NewRequestWithContext(reqCtx, http.MethodPost, url, body)
	if err != nil {
		logProbeError("upload", err)
		return true
	}
	req.ContentLength = int64(len(payload))
	req.Header.Set("Content-Type", "application/octet-stream")

	resp, err := client.Do(req)
	if err != nil {
		if reqCtx.Err() != nil {
			return false // shutdown or idle gate — expected
		}
		logProbeError("upload", err)
		return true
	}
	defer resp.Body.Close()

	_, copyErr := io.Copy(io.Discard, resp.Body)
	if resp.StatusCode >= 400 {
		logProbeError("upload", fmt.Errorf("HTTP %d from %s", resp.StatusCode, url))
		return true
	}
	if copyErr != nil {
		if reqCtx.Err() != nil {
			return false
		}
		logProbeError("upload", copyErr)
		return true
	}
	return false
}

func (c *countingReader) Read(p []byte) (int, error) {
	n, err := c.reader.Read(p)
	if n > 0 {
		c.count.Add(int64(n))
	}
	return n, err
}

func (c *countingReadCloser) Read(p []byte) (int, error) {
	n, err := c.ReadCloser.Read(p)
	if n > 0 {
		c.count.Add(int64(n))
	}
	return n, err
}

func writeStateFile(path string, state State) error {
	return writeJSONFile(path, state, ".latest-*.tmp")
}

func writeControlCommand(path string, command string, at time.Time) error {
	command = strings.TrimSpace(command)
	if !isValidControlCommand(command) {
		return fmt.Errorf("invalid control command %q", command)
	}
	return writeJSONFile(path, controlCommand{
		Command:   command,
		Timestamp: at.UnixNano(),
	}, ".control-*.tmp")
}

func writeJSONFile(path string, value any, tempPattern string) error {
	if err := os.MkdirAll(filepath.Dir(path), 0755); err != nil {
		return err
	}
	data, err := json.MarshalIndent(value, "", "  ")
	if err != nil {
		return err
	}
	data = append(data, '\n')

	tmp, err := os.CreateTemp(filepath.Dir(path), tempPattern)
	if err != nil {
		return err
	}
	tmpName := tmp.Name()
	committed := false
	defer func() {
		if !committed {
			_ = os.Remove(tmpName)
		}
	}()

	if _, err := tmp.Write(data); err != nil {
		_ = tmp.Close()
		return err
	}
	if err := tmp.Chmod(0644); err != nil {
		_ = tmp.Close()
		return err
	}
	if err := tmp.Close(); err != nil {
		return err
	}
	if err := os.Rename(tmpName, path); err != nil {
		return err
	}
	committed = true
	return nil
}

func pauseProbe() int {
	now := time.Now()
	if err := writeControlCommand(homePath(controlRelPath), controlPause, now); err != nil {
		fmt.Fprintln(os.Stderr, err)
		return 1
	}
	return writeControlState("paused", "paused", now)
}

// resumeProbe hands a resume command to the RUNNING daemon and exits.
//
// It must never call run() itself. The original implementation did, which forked
// a second probe in the foreground that competed with the launchd-managed one for
// latest.json — two writers, neither authoritative, and the CLI call never
// returned. `pause`/`resume` are control messages, not daemon entry points.
func resumeProbe() int {
	now := time.Now()
	if err := writeControlCommand(homePath(controlRelPath), controlResume, now); err != nil {
		fmt.Fprintln(os.Stderr, err)
		return 1
	}
	return writeControlState("running", "idle", now)
}

// requestCapacityTest asks the running daemon to run a capacity test now instead
// of waiting for the next scheduled one. Like pause/resume, it is a message --
// it never measures anything itself.
func requestCapacityTest() int {
	now := time.Now()
	if err := writeControlCommand(homePath(controlRelPath), controlTest, now); err != nil {
		fmt.Fprintln(os.Stderr, err)
		return 1
	}
	return 0
}

func resetPeaks() int {
	now := time.Now()
	if err := writeControlCommand(homePath(controlRelPath), controlReset, now); err != nil {
		fmt.Fprintln(os.Stderr, err)
		return 1
	}
	statePath := homePath(stateRelPath)
	state, err := readStateFile(statePath)
	if err != nil && !errors.Is(err, os.ErrNotExist) {
		fmt.Fprintln(os.Stderr, err)
		return 1
	}
	if errors.Is(err, os.ErrNotExist) {
		state = defaultState("stopped", "stopped")
	} else {
		state = normalizeState(state)
	}
	state.Mode = "live"
	state.DownloadPeakMbps = state.DownloadMbps
	state.UploadPeakMbps = state.UploadMbps
	state.SessionDownloadPeakMbps = state.DownloadMbps
	state.SessionUploadPeakMbps = state.UploadMbps
	state.UpdatedAt = now.Unix()
	state.Error = nil
	if err := writeStateFile(statePath, state); err != nil {
		fmt.Fprintln(os.Stderr, err)
		return 1
	}
	return 0
}

func printStatus() int {
	statePath := homePath(stateRelPath)
	state, err := readStateFile(statePath)
	if err != nil {
		if !errors.Is(err, os.ErrNotExist) {
			fmt.Fprintln(os.Stderr, err)
			return 1
		}
		state = defaultState("stopped", "stopped")
	} else {
		state = normalizeState(state)
	}
	if state.Status == "running" && !livePIDExists() {
		state.Status = "stopped"
		state.Phase = "stopped"
		state.PID = nil
		state.UpdatedAt = time.Now().Unix()
	}

	data, err := json.MarshalIndent(state, "", "  ")
	if err != nil {
		fmt.Fprintln(os.Stderr, err)
		return 1
	}
	fmt.Println(string(data))
	return 0
}

func writeControlState(status string, phase string, now time.Time) int {
	statePath := homePath(stateRelPath)
	state, err := readStateFile(statePath)
	if err != nil {
		if !errors.Is(err, os.ErrNotExist) {
			fmt.Fprintln(os.Stderr, err)
			return 1
		}
		state = defaultState(status, phase)
	} else {
		state = normalizeState(state)
	}
	state.Mode = "live"
	state.Status = status
	state.Phase = phase
	state.PID = nil
	state.UpdatedAt = now.Unix()
	if state.StartedAt == 0 {
		state.StartedAt = state.UpdatedAt
	}
	state.Error = nil
	if err := writeStateFile(statePath, state); err != nil {
		fmt.Fprintln(os.Stderr, err)
		return 1
	}
	return 0
}

func readControlCommand(path string) (controlCommand, error) {
	data, err := os.ReadFile(path)
	if err != nil {
		return controlCommand{}, err
	}
	var command controlCommand
	if err := json.Unmarshal(data, &command); err != nil {
		return controlCommand{}, err
	}
	command.Command = strings.TrimSpace(command.Command)
	if !isValidControlCommand(command.Command) {
		return controlCommand{}, fmt.Errorf("invalid control command %q", command.Command)
	}
	return command, nil
}

func pendingControlCommand(path string, afterTimestamp int64) (controlCommand, bool, error) {
	command, err := readControlCommand(path)
	if err != nil {
		if errors.Is(err, os.ErrNotExist) {
			return controlCommand{}, false, nil
		}
		return controlCommand{}, false, err
	}
	if command.Timestamp <= afterTimestamp {
		if err := clearControlFileIfSame(path, command); err != nil {
			return controlCommand{}, false, err
		}
		return command, false, nil
	}
	return command, true, nil
}

func clearControlFile(path string) error {
	err := os.Remove(path)
	if err != nil && !errors.Is(err, os.ErrNotExist) {
		return err
	}
	return nil
}

func clearControlFileIfSame(path string, expected controlCommand) error {
	current, err := readControlCommand(path)
	if err != nil {
		if errors.Is(err, os.ErrNotExist) {
			return nil
		}
		return err
	}
	if current == expected {
		return clearControlFile(path)
	}
	return nil
}

// probeStatus maps the runtime flags onto the status/phase/pid triple published
// in latest.json.
//
// A paused probe reports "paused" with no PID but keeps refreshing updated_at, so
// the menu bar app renders "paused" rather than treating frozen numbers as a dead
// probe and trying to restart it. "idle" means passive sampling only -- live, but
// generating no traffic; "testing" means a capacity burst is in flight.
func probeStatus(paused bool, testing bool, pid int) (string, string, any) {
	switch {
	case paused:
		return "paused", "paused", nil
	case testing:
		return "running", "testing", pid
	default:
		return "running", "idle", pid
	}
}

func isValidControlCommand(command string) bool {
	switch command {
	case controlPause, controlResume, controlReset, controlTest:
		return true
	default:
		return false
	}
}

func retainLiveRates(rawDown float64, rawUp float64, lastDown float64, lastUp float64, downAdvanced bool, upAdvanced bool) (float64, float64) {
	return retainLiveRate(rawDown, lastDown, downAdvanced), retainLiveRate(rawUp, lastUp, upAdvanced)
}

func retainLiveRate(raw float64, last float64, advanced bool) float64 {
	if !advanced && last > 0 {
		return last
	}
	return raw
}

func resetSessionPeaks(sessionDownPeak *float64, sessionUpPeak *float64, currentDown float64, currentUp float64) {
	*sessionDownPeak = currentDown
	*sessionUpPeak = currentUp
}

// gateContext derives a child context from parent that is cancelled either when
// parent is cancelled or when the active phase leaves the measuring state. This
// lets an in-flight transfer abort the instant the idle window begins.
func gateContext(parent context.Context, activePhase *atomic.Int64) (context.Context, context.CancelFunc) {
	ctx, cancel := context.WithCancel(parent)
	go func() {
		ticker := time.NewTicker(50 * time.Millisecond)
		defer ticker.Stop()
		for {
			select {
			case <-ctx.Done():
				return
			case <-ticker.C:
				if activePhase.Load() != activePhaseMeasuring {
					cancel()
					return
				}
			}
		}
	}()
	return ctx, cancel
}

// peakStreak accepts a candidate peak only after it has been matched or exceeded
// on peakSustainSamples consecutive samples, filtering out single-sample TCP
// bursts that would otherwise inflate the displayed session maximum.
type peakStreak struct {
	candidate float64
	count     int
}

func newPeakStreak() *peakStreak { return &peakStreak{} }

func (p *peakStreak) reset() {
	p.candidate = 0
	p.count = 0
}

// accept reports whether a new session peak should be adopted. When ok is true,
// adopt is the value to store: the lowest reading seen across the sustaining
// streak, so a lone spike followed by lower-but-still-high readings promotes the
// safe sustained value rather than the spike itself.
func (p *peakStreak) accept(value float64, currentPeak float64) (adopt float64, ok bool) {
	if value <= currentPeak {
		p.reset()
		return 0, false
	}
	if p.count == 0 || value < p.candidate {
		p.candidate = value
	}
	p.count++
	if p.count >= peakSustainSamples {
		promoted := p.candidate
		p.reset()
		return promoted, true
	}
	return 0, false
}

func readStateFile(path string) (State, error) {
	data, err := os.ReadFile(path)
	if err != nil {
		return State{}, err
	}
	var state State
	if err := json.Unmarshal(data, &state); err != nil {
		return State{}, err
	}
	return state, nil
}

func defaultState(status string, phase string) State {
	now := time.Now().Unix()
	return State{
		Mode:      "live",
		Status:    status,
		Phase:     phase,
		PID:       nil,
		UpdatedAt: now,
		StartedAt: 0,
		Error:     nil,
	}
}

func normalizeState(state State) State {
	state.Mode = "live"
	switch state.Status {
	case "running":
		state.Phase = "parallel"
	case "paused":
		state.Phase = "paused"
		state.PID = nil
	case "error":
		state.Phase = "error"
		state.PID = nil
	case "stopped":
		state.Phase = "stopped"
		state.PID = nil
	default:
		state.Status = "stopped"
		state.Phase = "stopped"
		state.PID = nil
	}
	return state
}

func homePath(rel string) string {
	if filepath.IsAbs(rel) {
		return rel
	}
	home, err := os.UserHomeDir()
	if err != nil || home == "" {
		return rel
	}
	return filepath.Join(home, rel)
}

// testInterval and testDuration are the bandwidth dial, overridable from the
// LaunchAgent so the trade-off can be retuned without a rebuild.
//
// Measured cost at the defaults: one 6s test moves ~308 MB on a 500 Mbit line,
// so 48 tests/day ≈ 15 GB/day. Doubling the interval halves that; halving the
// duration halves it again at the cost of a noisier capacity figure (TCP needs a
// moment to ramp, which is what activeTestWarmup already discards).
func testInterval() time.Duration {
	return durationEnv("SPEEDTEST_TEST_INTERVAL", activeTestInterval)
}

func testDuration() time.Duration {
	return durationEnv("SPEEDTEST_TEST_DURATION", activeTestDuration)
}

func durationEnv(name string, fallback time.Duration) time.Duration {
	raw := strings.TrimSpace(os.Getenv(name))
	if raw == "" {
		return fallback
	}
	value, err := time.ParseDuration(raw)
	if err != nil || value <= 0 {
		fmt.Fprintf(os.Stderr, "%s=%q is not a valid duration, using %v\n", name, raw, fallback)
		return fallback
	}
	return value
}

func downloadURL() string {
	if value := strings.TrimSpace(os.Getenv("SPEEDTEST_LIVE_DOWNLOAD_URL")); value != "" {
		return value
	}
	return defaultDownloadURL
}

func uploadURL() string {
	if value := strings.TrimSpace(os.Getenv("SPEEDTEST_LIVE_UPLOAD_URL")); value != "" {
		return value
	}
	return defaultUploadURL
}

func livePIDExists() bool {
	data, err := os.ReadFile(homePath(pidRelPath))
	if err != nil {
		return false
	}
	pid, err := strconv.Atoi(strings.TrimSpace(string(data)))
	if err != nil || pid <= 0 {
		return false
	}
	return syscall.Kill(pid, 0) == nil
}

func sleepOrDone(ctx context.Context, duration time.Duration) bool {
	timer := time.NewTimer(duration)
	defer timer.Stop()
	select {
	case <-ctx.Done():
		return false
	case <-timer.C:
		return true
	}
}

func logProbeError(phase string, err error) {
	if err == nil {
		return
	}
	path := homePath(logRelPath)
	if mkErr := os.MkdirAll(filepath.Dir(path), 0755); mkErr != nil {
		return
	}
	f, openErr := os.OpenFile(path, os.O_CREATE|os.O_WRONLY|os.O_APPEND, 0644)
	if openErr != nil {
		return
	}
	defer f.Close()
	_, _ = fmt.Fprintf(f, "%s %s: %v\n", time.Now().Format(time.RFC3339), phase, err)
}
