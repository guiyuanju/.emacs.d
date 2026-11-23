package supervisor

import (
	"context"
	"errors"
	"os"
	"path/filepath"
	"strings"
	"sync"
	"syscall"
	"testing"
	"time"
)

// procs fakes the process table.
type procs struct {
	mu      sync.Mutex
	alive   map[int]bool
	signals []syscall.Signal
	// dieOn is the signal that kills a process; 0 never.
	dieOn syscall.Signal
}

func (p *procs) set(pid int, alive bool) {
	p.mu.Lock()
	defer p.mu.Unlock()
	p.alive[pid] = alive
}

func (p *procs) isAlive(pid int) bool {
	p.mu.Lock()
	defer p.mu.Unlock()
	return p.alive[pid]
}

func (p *procs) signal(pid int, sig syscall.Signal) error {
	p.mu.Lock()
	defer p.mu.Unlock()
	p.signals = append(p.signals, sig)
	if sig == p.dieOn || sig == syscall.SIGKILL {
		p.alive[pid] = false
	}
	return nil
}

func (p *procs) sent() []syscall.Signal {
	p.mu.Lock()
	defer p.mu.Unlock()
	return append([]syscall.Signal(nil), p.signals...)
}

type fakeBridge struct {
	mu      sync.Mutex
	online  bool
	pingErr error
	calls   []string
	onCall  func(method string)
}

func (b *fakeBridge) Online() bool {
	b.mu.Lock()
	defer b.mu.Unlock()
	return b.online
}

func (b *fakeBridge) Ping(context.Context) error {
	b.mu.Lock()
	defer b.mu.Unlock()
	return b.pingErr
}

func (b *fakeBridge) Call(_ context.Context, method string, _, _ any) error {
	b.mu.Lock()
	b.calls = append(b.calls, method)
	fn := b.onCall
	b.mu.Unlock()
	if fn != nil {
		fn(method)
	}
	return nil
}

type harness struct {
	t      *testing.T
	s      *Supervisor
	p      *procs
	b      *fakeBridge
	starts string
}

func newHarness(t *testing.T, opts Options) *harness {
	t.Helper()
	dir := t.TempDir()
	h := &harness{t: t, p: &procs{alive: map[int]bool{}}, b: &fakeBridge{}, starts: filepath.Join(dir, "starts")}
	if opts.Start == nil {
		opts.Start = []string{"/bin/sh", "-c", "echo start >>" + h.starts}
	}
	opts.Alive, opts.Signal = h.p.isAlive, h.p.signal
	fast := Options{PingEvery: 10 * time.Millisecond, PingTimeout: 50 * time.Millisecond, Poll: 5 * time.Millisecond,
		QuitWait: 50 * time.Millisecond, TermWait: 50 * time.Millisecond, KillWait: 50 * time.Millisecond,
		Settle: time.Millisecond, ConnectWait: 500 * time.Millisecond}
	for _, f := range []struct{ dst, src *time.Duration }{
		{&opts.PingEvery, &fast.PingEvery}, {&opts.PingTimeout, &fast.PingTimeout}, {&opts.Poll, &fast.Poll},
		{&opts.QuitWait, &fast.QuitWait}, {&opts.TermWait, &fast.TermWait}, {&opts.KillWait, &fast.KillWait},
		{&opts.Settle, &fast.Settle}, {&opts.ConnectWait, &fast.ConnectWait},
	} {
		if *f.dst == 0 {
			*f.dst = *f.src
		}
	}
	h.s = New(opts, h.b, nil, nil)
	ctx, cancel := context.WithCancel(context.Background())
	done := make(chan struct{})
	go func() { h.s.Run(ctx); close(done) }()
	t.Cleanup(func() { cancel(); <-done })
	return h
}

func (h *harness) startCount() int {
	b, _ := os.ReadFile(h.starts)
	return strings.Count(string(b), "start")
}

func (h *harness) wait(what string, ok func() bool) {
	h.t.Helper()
	deadline := time.Now().Add(3 * time.Second)
	for !ok() {
		if time.Now().After(deadline) {
			h.t.Fatalf("timed out waiting for %s; status %+v", what, h.s.Status())
		}
		time.Sleep(2 * time.Millisecond)
	}
}

func (h *harness) state(want State) {
	h.t.Helper()
	h.wait("state "+string(want), func() bool { return h.s.Status().State == want })
}

func (h *harness) connect(pid int) {
	h.p.set(pid, true)
	h.b.mu.Lock()
	h.b.online = true
	h.b.mu.Unlock()
	h.s.Hello(pid)
}

func (h *harness) disconnect() {
	h.b.mu.Lock()
	h.b.online = false
	h.b.mu.Unlock()
	h.s.Gone()
}

func TestCrashRestartsEmacs(t *testing.T) {
	h := newHarness(t, Options{})
	if st := h.s.Status(); st.State != Unknown || !st.CanRestart {
		t.Fatalf("initial status %+v", st)
	}
	h.connect(100)
	h.state(Online)

	h.disconnect()
	h.state(Disconnected)
	h.p.set(100, false)
	h.state(Restarting)
	h.wait("Emacs to be started", func() bool { return h.startCount() == 1 })
	if st := h.s.Status(); st.Crashes != 1 || st.LastCrash == nil {
		t.Fatalf("status after crash %+v", st)
	}
	h.connect(101)
	h.state(Online)
	if st := h.s.Status(); st.PID != 101 || st.Error != "" {
		t.Fatalf("status after reconnect %+v", st)
	}
}

func TestByeMeansQuit(t *testing.T) {
	h := newHarness(t, Options{})
	h.connect(100)
	h.s.Bye()
	h.disconnect()
	h.p.set(100, false)
	h.state(Stopped)
	time.Sleep(30 * time.Millisecond)
	if n := h.startCount(); n != 0 {
		t.Fatalf("started %d times after a quit", n)
	}
}

func TestReconnectWithoutExit(t *testing.T) {
	h := newHarness(t, Options{})
	h.connect(100)
	h.disconnect()
	h.state(Disconnected)
	h.connect(100)
	h.state(Online)
	// A watcher of the old connection must not report the process later.
	h.p.set(100, false)
	time.Sleep(30 * time.Millisecond)
	if st := h.s.Status(); st.State != Online || h.startCount() != 0 {
		t.Fatalf("status %+v, starts %d", st, h.startCount())
	}
}

func TestCrashLimit(t *testing.T) {
	h := newHarness(t, Options{CrashLimit: 1})
	h.connect(100)
	h.disconnect()
	h.p.set(100, false)
	h.wait("first restart", func() bool { return h.startCount() == 1 })
	h.connect(101)
	h.state(Online)
	h.disconnect()
	h.p.set(101, false)
	h.state(Crashed)
	if st := h.s.Status(); st.Crashes != 2 || !strings.Contains(st.Error, "not restarting") {
		t.Fatalf("status %+v", st)
	}
	if n := h.startCount(); n != 1 {
		t.Fatalf("started %d times", n)
	}
}

func TestNoStartCommand(t *testing.T) {
	h := newHarness(t, Options{Start: []string{}})
	h.connect(100)
	h.disconnect()
	h.p.set(100, false)
	h.state(Crashed)
	if err := h.s.Restart(); !errors.Is(err, ErrUnavailable) {
		t.Fatalf("Restart: %v", err)
	}
	if h.s.Status().CanRestart {
		t.Fatal("CanRestart without a start command")
	}
}

func TestRestartAsksEmacsFirst(t *testing.T) {
	h := newHarness(t, Options{})
	h.connect(100)
	h.b.onCall = func(method string) {
		if method == MethodRestart {
			go func() {
				h.s.Bye()
				h.disconnect()
				h.p.set(100, false)
			}()
		}
	}
	if err := h.s.Restart(); err != nil {
		t.Fatal(err)
	}
	if err := h.s.Restart(); !errors.Is(err, ErrBusy) {
		t.Fatalf("second Restart: %v", err)
	}
	h.wait("Emacs to be started", func() bool { return h.startCount() == 1 })
	if s := h.p.sent(); len(s) != 0 {
		t.Fatalf("signals %v for an Emacs that quit", s)
	}
	h.state(Restarting)
	h.connect(101)
	h.state(Online)
	if st := h.s.Status(); st.Crashes != 0 {
		t.Fatalf("a requested restart counted as a crash: %+v", st)
	}
}

func TestRestartEscalates(t *testing.T) {
	h := newHarness(t, Options{})
	h.p.dieOn = syscall.SIGTERM
	h.connect(100)
	if err := h.s.Restart(); err != nil {
		t.Fatal(err)
	}
	h.wait("Emacs to be started", func() bool { return h.startCount() == 1 })
	if s := h.p.sent(); len(s) != 1 || s[0] != syscall.SIGTERM {
		t.Fatalf("signals %v, want SIGTERM", s)
	}
	h.b.mu.Lock()
	calls := h.b.calls
	h.b.mu.Unlock()
	if len(calls) != 1 || calls[0] != MethodRestart {
		t.Fatalf("calls %v", calls)
	}
	// The old Emacs reconnecting does not end the restart.
	h.s.Hello(100)
	if st := h.s.Status(); st.State != Restarting {
		t.Fatalf("status after the old pid's hello %+v", st)
	}
}

func TestRestartTimesOutWaitingForConnect(t *testing.T) {
	h := newHarness(t, Options{ConnectWait: 30 * time.Millisecond})
	if err := h.s.Restart(); err != nil {
		t.Fatal(err)
	}
	h.state(Disconnected)
	if st := h.s.Status(); !strings.Contains(st.Error, "did not connect") {
		t.Fatalf("status %+v", st)
	}
	if h.startCount() != 1 {
		t.Fatalf("starts %d", h.startCount())
	}
}

func TestUnresponsive(t *testing.T) {
	h := newHarness(t, Options{Misses: 2})
	h.connect(100)
	h.b.mu.Lock()
	h.b.pingErr = errors.New("timeout")
	h.b.mu.Unlock()
	h.state(Unresponsive)
	h.b.mu.Lock()
	h.b.pingErr = nil
	h.b.mu.Unlock()
	h.state(Online)
	if h.startCount() != 0 || len(h.p.sent()) != 0 {
		t.Fatal("an unresponsive Emacs was restarted")
	}
}
