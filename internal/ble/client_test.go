package ble

import (
	"context"
	"errors"
	"sync"
	"sync/atomic"
	"testing"
	"time"
)

// failingEnable returns an enable func that fails the first n calls.
func failingEnable(n int32, calls *atomic.Int32) func() error {
	return func() error {
		if calls.Add(1) <= n {
			return errors.New("timeout enabling CentralManager")
		}
		return nil
	}
}

func TestAdapterGate_RetriesAfterFailedEnable(t *testing.T) {
	var calls atomic.Int32
	g := &adapterGate{enable: failingEnable(3, &calls)}

	for i := 1; i <= 3; i++ {
		err := g.ensure()
		if !errors.Is(err, ErrAdapterNotReady) {
			t.Fatalf("call %d: err = %v, want ErrAdapterNotReady", i, err)
		}
	}
	if err := g.ensure(); err != nil {
		t.Fatalf("call 4: err = %v, want nil once the cause is gone", err)
	}
	if err := g.ensure(); err != nil {
		t.Fatalf("call 5: %v", err)
	}
	if got := calls.Load(); got != 4 {
		t.Errorf("enable calls = %d, want 4 (success is cached, failures are not)", got)
	}
}

func TestAdapterGate_NeverEnablesConcurrently(t *testing.T) {
	var inFlight, maxInFlight, calls atomic.Int32
	g := &adapterGate{enable: func() error {
		n := inFlight.Add(1)
		defer inFlight.Add(-1)
		if n > maxInFlight.Load() {
			maxInFlight.Store(n)
		}
		time.Sleep(5 * time.Millisecond)
		if calls.Add(1) < 3 {
			return errors.New("not yet")
		}
		return nil
	}}

	var wg sync.WaitGroup
	for range 8 {
		wg.Add(1)
		go func() { defer wg.Done(); _ = g.ensure() }()
	}
	wg.Wait()
	if maxInFlight.Load() != 1 {
		t.Errorf("max concurrent enables = %d, want 1", maxInFlight.Load())
	}
}

// gateDialer is a LinkDialer whose Pick goes through an adapterGate like the
// production dialer, so a failing enable surfaces as a resolve error.
type gateDialer struct {
	*fakeDialer
	gate *adapterGate
}

func (d gateDialer) Pick(ctx context.Context, timeout time.Duration) (Discovered, error) {
	if err := d.gate.ensure(); err != nil {
		return Discovered{}, err
	}
	return d.fakeDialer.Pick(ctx, timeout)
}

func TestLink_ConnectsAfterAdapterEnableRecovers(t *testing.T) {
	var enableCalls atomic.Int32
	dialer := gateDialer{
		fakeDialer: &fakeDialer{pickResult: Discovered{Address: "picked-1"}},
		gate:       &adapterGate{enable: failingEnable(1, &enableCalls)},
	}

	var mu sync.Mutex
	var states []error
	link := NewLink(LinkConfig{
		PollInterval: 50 * time.Millisecond,
		Watchdog:     time.Second,
		Logger:       quietLogger(),
		OnStatus:     func(Status) {},
		OnAdapterState: func(err error) {
			mu.Lock()
			defer mu.Unlock()
			states = append(states, err)
		},
	}).WithDialer(dialer)

	ctx, cancel := context.WithCancel(context.Background())
	done := make(chan struct{})
	go func() { _ = link.Run(ctx); close(done) }()
	defer func() { cancel(); <-done }()

	// First resolve fails (enable #1), Backoff(1) = 1 s, then enable #2 works.
	if !waitUntil(3*time.Second, link.Connected) {
		t.Fatalf("link never connected after the adapter recovered; enable calls=%d", enableCalls.Load())
	}
	mu.Lock()
	defer mu.Unlock()
	if len(states) < 2 || !errors.Is(states[0], ErrAdapterNotReady) || states[len(states)-1] != nil {
		t.Errorf("adapter state callbacks = %v, want [ErrAdapterNotReady ... nil]", states)
	}
}
