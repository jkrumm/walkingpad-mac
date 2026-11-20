package api

import (
	"bytes"
	"context"
	"encoding/json"
	"flag"
	"os"
	"path/filepath"
	"sort"
	"strings"
	"testing"
	"time"

	"github.com/jkrumm/king-smith-walkingpad-mac/internal/ble"
	"github.com/jkrumm/king-smith-walkingpad-mac/internal/store"
)

// The golden contract: every response shape the app decodes is written to
// contracts/fixtures/ from a fixed fixture, and the Swift client
// (apple/Packages/PadKit) decodes the same files. A drift fails here until the
// files are regenerated with `make contracts`, and then fails the Swift side
// until its models follow.
var updateContracts = flag.Bool("update", false, "rewrite contracts/fixtures from the handlers")

const contractsDir = "../../contracts/fixtures"

// Fixed instants keep the fixtures byte-stable. They lie far from "today", so
// the today/week/month windows of /status stay empty and only /summary?period=all
// reads the seeded sessions.
var (
	contractT0 = time.Date(2026, 5, 17, 13, 22, 11, 0, time.UTC)
	contractT1 = time.Date(2026, 5, 18, 8, 0, 0, 0, time.UTC)
	contractT2 = time.Date(2026, 5, 19, 17, 30, 0, 0, time.UTC)
)

const (
	contractUUIDOpen   = "6f1c2a1e-3b4d-4c5e-8f60-718293a4b5c6"
	contractUUIDClosed = "0d9e8f7a-6b5c-4d3e-9f21-0a1b2c3d4e5f"
	contractUUIDSynced = "a1b2c3d4-e5f6-4a7b-8c9d-0e1f2a3b4c5d"
)

type contractCase struct {
	name   string // file name under contracts/fixtures, without .json
	method string
	path   string
	body   any
	status int
	setup  func(t *testing.T, r *rig)
}

// contractUUIDLive replaces the random UUID the session manager mints for the
// in-flight session, the one value of a response the fixture cannot pin.
const contractUUIDLive = "5e4d3c2b-1a09-4f8e-9d7c-6b5a49382716"

func TestContractFixtures(t *testing.T) {
	cases := []contractCase{
		{name: "health", method: "GET", path: "/health", status: 200},
		{name: "status-disconnected", method: "GET", path: "/status", status: 200},
		statusCase("status-stopped", ble.BeltStopped, ble.ModeStandby, 0),
		statusCase("status-starting", ble.BeltStarting2, ble.ModeManual, 0),
		statusCase("status-active", ble.BeltActive, ble.ModeManual, 4.5),
		statusCase("status-stopping", ble.BeltStopping, ble.ModeManual, 1.2),
		statusCase("status-standby", ble.BeltStandby, ble.ModeStandby, 0),
		statusCase("status-unknown", ble.BeltState(1), ble.ModeAuto, 0),
		{name: "status-current-session", method: "GET", path: "/status", status: 200, setup: seedCurrentSession},
		{name: "sessions", method: "GET", path: "/sessions", status: 200, setup: seedClosedSessions},
		{name: "sessions-empty", method: "GET", path: "/sessions?limit=3", status: 200},
		{name: "session-detail", method: "GET", path: "/sessions/" + contractUUIDClosed, status: 200, setup: seedClosedSessions},
		{name: "summary-all", method: "GET", path: "/summary?period=all", status: 200, setup: seedClosedSessions},
		{name: "ok", method: "POST", path: "/speed", body: map[string]any{"speed_kmh": 3.5}, status: 200},
		{
			name: "sync", method: "POST", path: "/sync/argo", status: 200,
			setup: func(_ *testing.T, r *rig) { r.syncer.synced, r.syncer.failed = 2, 1 },
		},
		{name: "error-bad-request", method: "GET", path: "/sessions?limit=0", status: 400},
		{name: "error-not-found", method: "GET", path: "/sessions/" + contractUUIDOpen, status: 404},
		{
			name: "error-unavailable", method: "POST", path: "/stop", status: 503,
			setup: func(_ *testing.T, r *rig) { r.ctrl.err = ErrControllerUnavailable },
		},
	}

	written := map[string]bool{}
	for _, tc := range cases {
		written[tc.name+".json"] = true
		t.Run(tc.name, func(t *testing.T) {
			r := newRig(t, "")
			if tc.setup != nil {
				tc.setup(t, r)
			}
			code, body := r.do(t, tc.method, tc.path, tc.body)
			if code != tc.status {
				t.Fatalf("%s %s = %d, want %d; body=%s", tc.method, tc.path, code, tc.status, body)
			}
			if cur := r.mgr.CurrentSession(); cur != nil {
				body = bytes.ReplaceAll(body, []byte(cur.UUID), []byte(contractUUIDLive))
			}
			checkGolden(t, filepath.Join(contractsDir, tc.name+".json"), body)
		})
	}
	checkNoStaleFixtures(t, written)
}

func statusCase(name string, state ble.BeltState, mode ble.Mode, speed float64) contractCase {
	return contractCase{
		name: name, method: "GET", path: "/status", status: 200,
		setup: func(_ *testing.T, r *rig) {
			r.status.connected = true
			r.status.observed = contractT0
			r.status.frame = ble.Status{State: state, Mode: mode, SpeedKmh: speed}
			r.status.dev = DeviceInfo{Name: "WalkingPad", Address: "00000000-0000-0000-0000-000000000001", RSSI: -56}
		},
	}
}

// seedCurrentSession opens a session through the manager and pauses it, so
// its active window is closed and duration_s does not depend on the clock.
func seedCurrentSession(t *testing.T, r *rig) {
	t.Helper()
	ctx := context.Background()
	frames := []struct {
		at    time.Duration
		frame ble.Status
	}{
		{0, ble.Status{State: ble.BeltActive, Mode: ble.ModeManual, SpeedKmh: 4.0, Distance: 0, Steps: 0}},
		{60 * time.Second, ble.Status{State: ble.BeltActive, Mode: ble.ModeManual, SpeedKmh: 4.5, Distance: 70, Steps: 110}},
		{120 * time.Second, ble.Status{State: ble.BeltStopped, Mode: ble.ModeManual}},
	}
	for _, f := range frames {
		if err := r.mgr.Ingest(ctx, f.frame, contractT0.Add(f.at)); err != nil {
			t.Fatalf("ingest: %v", err)
		}
	}
	r.status.connected = true
	r.status.observed = contractT0.Add(120 * time.Second)
	r.status.frame = ble.Status{State: ble.BeltStopped, Mode: ble.ModeManual}
	r.status.dev = DeviceInfo{Name: "WalkingPad", Address: "00000000-0000-0000-0000-000000000001", RSSI: -61}
}

// seedClosedSessions writes two closed sessions (one synced to Argo) and one
// open one, with samples on the closed session in every belt state.
func seedClosedSessions(t *testing.T, r *rig) {
	t.Helper()
	ctx := context.Background()
	st := r.store

	closedID := mustOpen(t, st, contractUUIDClosed, contractT0)
	states := []ble.BeltState{
		ble.BeltStarting3, ble.BeltStarting2, ble.BeltStarting1, ble.BeltActive,
		ble.BeltStopping, ble.BeltStopped, ble.BeltStandby, ble.BeltState(1),
	}
	for i, s := range states {
		speed := 0.0
		if s.IsRunning() {
			speed = 4.5
		}
		smp := store.Sample{
			SessionID: closedID, Ts: contractT0.Add(time.Duration(i) * time.Second),
			BeltState: int(s), SpeedKmh: speed, DistanceM: float64(i * 10), Steps: int64(i * 15),
		}
		if _, err := st.AppendSample(ctx, smp); err != nil {
			t.Fatalf("sample: %v", err)
		}
	}
	mustClose(t, st, closedID, contractT0.Add(754*time.Second), store.SessionTotals{
		DurationS: 754, DistanceM: 942, Steps: 1450, AvgSpeedKmh: 4.5, MaxSpeedKmh: 5, Kcal: 38.2,
	})

	syncedID := mustOpen(t, st, contractUUIDSynced, contractT1)
	mustClose(t, st, syncedID, contractT1.Add(1800*time.Second), store.SessionTotals{
		DurationS: 1800, DistanceM: 2100.5, Steps: 3300, AvgSpeedKmh: 4.2, MaxSpeedKmh: 4.8, Kcal: 96.4,
	})
	if err := st.MarkSynced(ctx, contractUUIDSynced, contractT1.Add(time.Hour)); err != nil {
		t.Fatalf("mark synced: %v", err)
	}

	mustOpen(t, st, contractUUIDOpen, contractT2)
}

func mustOpen(t *testing.T, st *store.Store, uuid string, at time.Time) int64 {
	t.Helper()
	id, err := st.OpenSession(context.Background(), uuid, at)
	if err != nil {
		t.Fatalf("open session: %v", err)
	}
	return id
}

func mustClose(t *testing.T, st *store.Store, id int64, at time.Time, totals store.SessionTotals) {
	t.Helper()
	if err := st.CloseSession(context.Background(), id, at, totals); err != nil {
		t.Fatalf("close session: %v", err)
	}
}

// checkGolden compares the response, indented, with the committed file, or
// rewrites the file under -update.
func checkGolden(t *testing.T, path string, body []byte) {
	t.Helper()
	var buf bytes.Buffer
	if err := json.Indent(&buf, bytes.TrimSpace(body), "", "  "); err != nil {
		t.Fatalf("indent: %v; body=%s", err, body)
	}
	buf.WriteByte('\n')
	got := buf.Bytes()

	if *updateContracts {
		if err := os.WriteFile(path, got, 0o600); err != nil {
			t.Fatalf("write %s: %v", path, err)
		}
		return
	}
	want, err := os.ReadFile(path) //nolint:gosec // path is a fixed fixture name
	if err != nil {
		t.Fatalf("read %s: %v (run `make contracts` to write it)", path, err)
	}
	if !bytes.Equal(got, want) {
		t.Errorf("response drifted from %s; if the change is intended, run `make contracts` and update PadKit\n--- got\n%s--- want\n%s",
			path, got, want)
	}
}

// checkNoStaleFixtures fails on a committed fixture no case writes, so a
// removed route or case cannot leave a file the Swift side still trusts.
func checkNoStaleFixtures(t *testing.T, written map[string]bool) {
	t.Helper()
	entries, err := os.ReadDir(contractsDir)
	if err != nil {
		t.Fatalf("read %s: %v", contractsDir, err)
	}
	var stale []string
	for _, e := range entries {
		if strings.HasSuffix(e.Name(), ".json") && !written[e.Name()] {
			stale = append(stale, e.Name())
		}
	}
	sort.Strings(stale)
	if len(stale) == 0 {
		return
	}
	if *updateContracts {
		for _, name := range stale {
			if err := os.Remove(filepath.Join(contractsDir, name)); err != nil {
				t.Fatalf("remove %s: %v", name, err)
			}
		}
		return
	}
	t.Errorf("fixtures no case writes: %v (run `make contracts`)", stale)
}
