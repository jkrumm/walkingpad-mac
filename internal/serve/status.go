package serve

import (
	"strings"
	"sync"
	"time"

	"github.com/jkrumm/walkingpad-mac/internal/api"
	"github.com/jkrumm/walkingpad-mac/internal/ble"
)

// statusProvider is the api.StatusProvider implementation backed by live BLE
// state. The BLE notification thread calls observe (and the link callbacks
// call connect/disconnect); HTTP handlers call LastFrame/DeviceInfo. All
// access goes through a single mutex — the methods are short and
// allocation-free, so contention is not a concern.
type statusProvider struct {
	mu        sync.Mutex
	frame     ble.Status
	observed  time.Time
	connected bool
	address   string
	name      string
	adapter   string // why the adapter is unusable; empty when it works
}

// newStatusProvider constructs an empty provider. name is the human-readable
// label reported via /status — typically just "WalkingPad".
func newStatusProvider(name string) *statusProvider {
	return &statusProvider{name: name}
}

// observe records the most recent decoded frame. Called from the BLE
// notification thread; must not block.
func (s *statusProvider) observe(frame ble.Status, ts time.Time) {
	s.mu.Lock()
	defer s.mu.Unlock()
	s.frame = frame
	s.observed = ts
}

// markConnected stamps the address bound by ble.Link.
func (s *statusProvider) markConnected(addr string) {
	s.mu.Lock()
	defer s.mu.Unlock()
	s.connected = true
	s.address = addr
}

// markDisconnected clears the connection flag. The last frame is intentionally
// preserved so the UI can still show the final reading.
func (s *statusProvider) markDisconnected() {
	s.mu.Lock()
	defer s.mu.Unlock()
	s.connected = false
}

// setAdapterState records whether the Bluetooth adapter is the reason the pad
// is not connected. Called from the link's retry loop.
func (s *statusProvider) setAdapterState(err error) {
	s.mu.Lock()
	defer s.mu.Unlock()
	if err == nil {
		s.adapter = ""
		return
	}
	s.adapter = adapterReason(err)
}

// AdapterError implements api.StatusProvider.
func (s *statusProvider) AdapterError() string {
	s.mu.Lock()
	defer s.mu.Unlock()
	return s.adapter
}

// adapterReason is the CoreBluetooth cause without the wrapping prefixes
// ("scan: " on the unpinned path, the ErrAdapterNotReady text on both).
func adapterReason(err error) string {
	msg := err.Error()
	if _, cause, ok := strings.Cut(msg, ble.ErrAdapterNotReady.Error()+": "); ok {
		return cause
	}
	return msg
}

// LastFrame implements api.StatusProvider.
func (s *statusProvider) LastFrame() (ble.Status, time.Time, bool) {
	s.mu.Lock()
	defer s.mu.Unlock()
	return s.frame, s.observed, s.connected
}

// DeviceInfo implements api.StatusProvider. RSSI is not available from the
// active connection (only from advertising scans) so it is always 0 for now.
func (s *statusProvider) DeviceInfo() api.DeviceInfo {
	s.mu.Lock()
	defer s.mu.Unlock()
	return api.DeviceInfo{Name: s.name, Address: s.address}
}
