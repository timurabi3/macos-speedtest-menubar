package main

import (
	"encoding/json"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"
)

func TestMbpsFromBytes(t *testing.T) {
	got := mbpsFromBytes(25_000_000, time.Second)
	if got != 200 {
		t.Fatalf("mbpsFromBytes = %v, want 200", got)
	}
}

func TestRollingOneSecondRates(t *testing.T) {
	r := newRateWindow(time.Second)
	start := time.Unix(100, 0)
	r.add(start, 0, 0)
	r.add(start.Add(500*time.Millisecond), 10_000_000, 2_000_000)
	r.add(start.Add(1*time.Second), 25_000_000, 6_250_000)
	down, up := r.rates(start.Add(1 * time.Second))
	if down != 200 {
		t.Fatalf("download rate = %v, want 200", down)
	}
	if up != 50 {
		t.Fatalf("upload rate = %v, want 50", up)
	}
}

func TestDefaultDownloadURLUsesLongLivedDownloadFile(t *testing.T) {
	t.Setenv("SPEEDTEST_LIVE_DOWNLOAD_URL", "")
	if strings.Contains(defaultDownloadURL, "speed.cloudflare.com") {
		t.Fatalf("defaultDownloadURL uses rate-limited Cloudflare endpoint: %s", defaultDownloadURL)
	}
	if !strings.Contains(defaultDownloadURL, "cachefly") {
		t.Fatalf("defaultDownloadURL = %s, want tested Cachefly download file", defaultDownloadURL)
	}
	if got := downloadURL(); got != defaultDownloadURL {
		t.Fatalf("downloadURL() = %s, want default %s", got, defaultDownloadURL)
	}

	override := "https://example.test/down"
	t.Setenv("SPEEDTEST_LIVE_DOWNLOAD_URL", override)
	if got := downloadURL(); got != override {
		t.Fatalf("downloadURL() with env override = %s, want %s", got, override)
	}
}

func TestWorkerCountsAreSane(t *testing.T) {
	if downloadWorkerCount <= 2 {
		t.Fatalf("downloadWorkerCount = %d, want more than 2", downloadWorkerCount)
	}
	if uploadWorkerCount <= 0 {
		t.Fatalf("uploadWorkerCount = %d, want positive", uploadWorkerCount)
	}
	if uploadWorkerCount != 4 {
		t.Fatalf("uploadWorkerCount = %d, want 4", uploadWorkerCount)
	}
}

func TestSampleWindowIsSnappy(t *testing.T) {
	// Always-on mode: the readout updates every sampleInterval, averaged over
	// rollingWindow. Guard the "live feel" invariants so a future edit can't
	// silently make the number sluggish or slower-than-visible.
	if sampleInterval > 250*time.Millisecond {
		t.Fatalf("sampleInterval=%v too slow for a live readout (want <=250ms)", sampleInterval)
	}
	if rollingWindow > time.Second {
		t.Fatalf("rollingWindow=%v too long for a live feel (want <=1s)", rollingWindow)
	}
	if rollingWindow < sampleInterval {
		t.Fatalf("rollingWindow=%v should span at least one sampleInterval=%v", rollingWindow, sampleInterval)
	}
}

func TestPeakStreakRejectsSingleSpike(t *testing.T) {
	p := newPeakStreak()
	// A lone spike above the current peak must NOT be adopted immediately.
	if _, ok := p.accept(630, 400); ok {
		t.Fatal("single spike should not be adopted with peakSustainSamples=2")
	}
	// Sustained on the next sample → adopt the lower (safe) sustained value.
	adopt, ok := p.accept(500, 400)
	if !ok {
		t.Fatal("sustained high reading should be adopted")
	}
	if adopt != 500 {
		t.Fatalf("adopt = %v, want 500 (the sustained minimum, not the 630 spike)", adopt)
	}
}

func TestPeakStreakResetsBelowPeak(t *testing.T) {
	p := newPeakStreak()
	if _, ok := p.accept(630, 400); ok {
		t.Fatal("first sample should not adopt")
	}
	// Drop below current peak → streak resets.
	if _, ok := p.accept(300, 400); ok {
		t.Fatal("reading below peak should not adopt")
	}
	// A fresh single high sample again should still need a second confirmation.
	if _, ok := p.accept(650, 400); ok {
		t.Fatal("streak should have reset; single sample must not adopt")
	}
}

func TestAtomicStateWriteShape(t *testing.T) {
	dir := t.TempDir()
	path := filepath.Join(dir, "latest.json")
	state := State{
		Mode:                    "live",
		Status:                  "running",
		Phase:                   "parallel",
		PID:                     os.Getpid(),
		DownloadMbps:            floatPtr(123.4),
		UploadMbps:              floatPtr(45.6),
		DownloadPeakMbps:        floatPtr(123.4),
		UploadPeakMbps:          floatPtr(45.6),
		SessionDownloadPeakMbps: floatPtr(200.1),
		SessionUploadPeakMbps:   floatPtr(50.2),
		UpdatedAt:               1783640000,
		StartedAt:               1783639900,
	}
	if err := writeStateFile(path, state); err != nil {
		t.Fatalf("writeStateFile error: %v", err)
	}
	data, err := os.ReadFile(path)
	if err != nil {
		t.Fatalf("read state: %v", err)
	}
	var decoded map[string]any
	if err := json.Unmarshal(data, &decoded); err != nil {
		t.Fatalf("json decode: %v", err)
	}
	if decoded["mode"] != "live" || decoded["status"] != "running" || decoded["phase"] != "parallel" {
		t.Fatalf("bad state shape: %#v", decoded)
	}
}

func TestRetainLiveRatesWithoutByteProgress(t *testing.T) {
	down, up := retainLiveRates(0, 0, 123.4, 45.6, false, false)
	if down != 123.4 {
		t.Fatalf("download retained = %v, want 123.4", down)
	}
	if up != 45.6 {
		t.Fatalf("upload retained = %v, want 45.6", up)
	}
}

func TestRetainLiveRatesAllowsFreshZeroBeforeFirstProgress(t *testing.T) {
	down, up := retainLiveRates(0, 0, 0, 0, false, false)
	if down != 0 || up != 0 {
		t.Fatalf("rates = %v/%v, want 0/0", down, up)
	}
}

func TestResetSessionPeaksUsesCurrentLiveValues(t *testing.T) {
	sessionDown := 500.0
	sessionUp := 100.0
	resetSessionPeaks(&sessionDown, &sessionUp, 42.5, 8.25)
	if sessionDown != 42.5 {
		t.Fatalf("session download peak = %v, want 42.5", sessionDown)
	}
	if sessionUp != 8.25 {
		t.Fatalf("session upload peak = %v, want 8.25", sessionUp)
	}
}

func TestControlCommandWriteReadPendingAndClear(t *testing.T) {
	dir := t.TempDir()
	path := filepath.Join(dir, "liveprobe-control.json")
	at := time.Unix(100, 123)

	if err := writeControlCommand(path, controlPause, at); err != nil {
		t.Fatalf("writeControlCommand error: %v", err)
	}

	command, pending, err := pendingControlCommand(path, at.Add(-time.Nanosecond).UnixNano())
	if err != nil {
		t.Fatalf("pendingControlCommand error: %v", err)
	}
	if !pending {
		t.Fatal("pendingControlCommand pending = false, want true")
	}
	if command.Command != controlPause || command.Timestamp != at.UnixNano() {
		t.Fatalf("command = %#v, want pause at %d", command, at.UnixNano())
	}

	if err := clearControlFileIfSame(path, command); err != nil {
		t.Fatalf("clearControlFileIfSame error: %v", err)
	}
	if _, err := os.Stat(path); !os.IsNotExist(err) {
		t.Fatalf("control file still exists or stat failed unexpectedly: %v", err)
	}
}

func TestResumeIsAValidControlCommand(t *testing.T) {
	// `resume` used to be CLI-only: it deleted the control file and then called
	// run(), forking a second daemon. It is now a real control message, so the
	// running probe must accept it.
	if !isValidControlCommand(controlResume) {
		t.Fatal("resume must be a valid control command")
	}
	for _, bad := range []string{"", "restart", "stop", "RESUME"} {
		if isValidControlCommand(bad) {
			t.Fatalf("isValidControlCommand(%q) = true, want false", bad)
		}
	}
}

func TestResumeControlCommandRoundTrip(t *testing.T) {
	dir := t.TempDir()
	path := filepath.Join(dir, "liveprobe-control.json")
	at := time.Unix(200, 77)

	if err := writeControlCommand(path, controlResume, at); err != nil {
		t.Fatalf("writeControlCommand error: %v", err)
	}
	command, pending, err := pendingControlCommand(path, at.Add(-time.Nanosecond).UnixNano())
	if err != nil {
		t.Fatalf("pendingControlCommand error: %v", err)
	}
	if !pending || command.Command != controlResume {
		t.Fatalf("command = %#v pending = %v, want resume pending", command, pending)
	}
}

func TestProbeStatusReflectsPause(t *testing.T) {
	status, phase, pid := probeStatus(false, 4242)
	if status != "running" || phase != "parallel" || pid != 4242 {
		t.Fatalf("running triple = %q/%q/%v, want running/parallel/4242", status, phase, pid)
	}

	status, phase, pid = probeStatus(true, 4242)
	if status != "paused" || phase != "paused" {
		t.Fatalf("paused triple = %q/%q, want paused/paused", status, phase)
	}
	// PID must be nil while paused: a non-nil PID makes `status` report a live
	// measuring probe, and livePIDExists() would keep confirming it.
	if pid != nil {
		t.Fatalf("paused pid = %v, want nil", pid)
	}
}

func TestStaleControlCommandIsNotPending(t *testing.T) {
	dir := t.TempDir()
	path := filepath.Join(dir, "liveprobe-control.json")
	at := time.Unix(100, 0)

	if err := writeControlCommand(path, controlReset, at); err != nil {
		t.Fatalf("writeControlCommand error: %v", err)
	}

	_, pending, err := pendingControlCommand(path, at.UnixNano())
	if err != nil {
		t.Fatalf("pendingControlCommand error: %v", err)
	}
	if pending {
		t.Fatal("pendingControlCommand pending = true, want false for stale command")
	}
	if _, err := os.Stat(path); !os.IsNotExist(err) {
		t.Fatalf("stale control file was not cleared: %v", err)
	}
}
