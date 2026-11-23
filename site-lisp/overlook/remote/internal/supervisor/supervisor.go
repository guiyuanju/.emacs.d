// Package supervisor watches the Emacs process behind the bridge: it restarts
// Emacs when it dies without saying goodbye, reports when it stops answering,
// and restarts it on request.
//
// The bridge tells it the pid (hello), an intentional disconnect (bye: Emacs
// quitting, or the bridge mode turned off) and the end of the connection. A
// process that disappears after a disconnect without bye has crashed. An
// unresponsive Emacs is only reported: long garbage collections and blocking
// commands look the same from here.
package supervisor

import (
	"context"
	"errors"
	"fmt"
	"log/slog"
	"os/exec"
	"sync"
	"syscall"
	"time"

	"github.com/guiyuanju/overlook/remote/internal/bridge"
)

// State is what the daemon knows about Emacs.
type State string

const (
	// Unknown: no Emacs connected since the daemon started.
	Unknown State = "unknown"
	// Online: connected and answering pings.
	Online State = "online"
	// Unresponsive: connected but missing pings.
	Unresponsive State = "unresponsive"
	// Disconnected: not connected; the process is alive or could not be checked.
	Disconnected State = "disconnected"
	// Restarting: quitting the old process or waiting for the new one to connect.
	Restarting State = "restarting"
	// Stopped: quit on purpose.
	Stopped State = "stopped"
	// Crashed: died without bye and was not restarted.
	Crashed State = "crashed"
)

// MethodRestart asks Emacs to save its buffers and quit.
const MethodRestart = bridge.MethodEmacsRestart

// Errors of Restart.
var (
	ErrBusy        = errors.New("Emacs is already restarting")
	ErrUnavailable = errors.New("no command to start Emacs (-emacs-start)")
)

// Status is reported to the admin socket and the page.
type Status struct {
	State State `json:"state"`
	PID   int   `json:"pid,omitempty"`
	// CanRestart is false without a start command.
	CanRestart bool `json:"canRestart"`
	// Crashes counts crashes since the daemon started; LastCrash is the latest.
	Crashes   int        `json:"crashes,omitempty"`
	LastCrash *time.Time `json:"lastCrash,omitempty"`
	// Error says why the last restart failed or was not attempted.
	Error string `json:"error,omitempty"`
}

// Bridge is the connection to Emacs.
type Bridge interface {
	Online() bool
	Ping(ctx context.Context) error
	Call(ctx context.Context, method string, params, result any) error
}

// Options tune the supervisor; zero fields take the defaults.
type Options struct {
	// Start launches Emacs; empty never launches it.
	Start []string
	// PingEvery and PingTimeout pace the liveness check; Misses missed pings in a row mean unresponsive.
	PingEvery, PingTimeout time.Duration
	Misses                 int
	// Poll is how often a disconnected process is checked.
	Poll time.Duration
	// QuitWait, TermWait and KillWait bound waiting for Emacs to exit after
	// asking it, after SIGTERM and after SIGKILL.
	QuitWait, TermWait, KillWait time.Duration
	// Settle is the pause between the old process going and the launch.
	Settle time.Duration
	// ConnectWait bounds waiting for a launched Emacs to connect.
	ConnectWait time.Duration
	// CrashLimit crashes within CrashWindow stop automatic restarts.
	CrashLimit  int
	CrashWindow time.Duration
	// Alive and Signal default to kill(2); tests replace them.
	Alive  func(pid int) bool
	Signal func(pid int, sig syscall.Signal) error
}

// DefaultOptions are used for zero fields.
var DefaultOptions = Options{
	PingEvery: 15 * time.Second, PingTimeout: 5 * time.Second, Misses: 2,
	Poll:     time.Second,
	QuitWait: 30 * time.Second, TermWait: 10 * time.Second, KillWait: 5 * time.Second,
	Settle: time.Second, ConnectWait: 2 * time.Minute,
	CrashLimit: 3, CrashWindow: 10 * time.Minute,
}

// Supervisor follows one Emacs at a time.
type Supervisor struct {
	opts    Options
	bridge  Bridge
	log     *slog.Logger
	changed func()

	mu         sync.Mutex
	state      State
	pid        int
	connected  bool
	bye        bool
	restarting bool
	// oldPID is the process a restart replaces; its hello does not end the restart.
	oldPID int
	// gen invalidates process watchers and pings whenever the connection changes.
	gen       int
	misses    int
	crashes   []time.Time
	total     int
	lastCrash time.Time
	err       string
	// seq numbers restarts, so a late step of an old one does nothing.
	seq    int
	ctx    context.Context
	cancel context.CancelFunc
}

// New returns a supervisor; changed is called after every status change.
func New(opts Options, bridge Bridge, log *slog.Logger, changed func()) *Supervisor {
	d := DefaultOptions
	if opts.PingEvery == 0 {
		opts.PingEvery = d.PingEvery
	}
	if opts.PingTimeout == 0 {
		opts.PingTimeout = d.PingTimeout
	}
	if opts.Misses == 0 {
		opts.Misses = d.Misses
	}
	if opts.Poll == 0 {
		opts.Poll = d.Poll
	}
	if opts.QuitWait == 0 {
		opts.QuitWait = d.QuitWait
	}
	if opts.TermWait == 0 {
		opts.TermWait = d.TermWait
	}
	if opts.KillWait == 0 {
		opts.KillWait = d.KillWait
	}
	if opts.Settle == 0 {
		opts.Settle = d.Settle
	}
	if opts.ConnectWait == 0 {
		opts.ConnectWait = d.ConnectWait
	}
	if opts.CrashLimit == 0 {
		opts.CrashLimit = d.CrashLimit
	}
	if opts.CrashWindow == 0 {
		opts.CrashWindow = d.CrashWindow
	}
	if opts.Alive == nil {
		opts.Alive = alive
	}
	if opts.Signal == nil {
		opts.Signal = func(pid int, sig syscall.Signal) error { return syscall.Kill(pid, sig) }
	}
	if log == nil {
		log = slog.New(slog.DiscardHandler)
	}
	if changed == nil {
		changed = func() {}
	}
	ctx, cancel := context.WithCancel(context.Background())
	return &Supervisor{opts: opts, bridge: bridge, log: log, changed: changed, state: Unknown, ctx: ctx, cancel: cancel}
}

func alive(pid int) bool {
	err := syscall.Kill(pid, 0)
	return err == nil || errors.Is(err, syscall.EPERM)
}

// Status reports the current state.
func (s *Supervisor) Status() Status {
	s.mu.Lock()
	defer s.mu.Unlock()
	st := Status{State: s.state, PID: s.pid, CanRestart: len(s.opts.Start) > 0, Crashes: s.total, Error: s.err}
	if !s.lastCrash.IsZero() {
		t := s.lastCrash
		st.LastCrash = &t
	}
	return st
}

// setLocked changes the state and reports whether it changed.
func (s *Supervisor) setLocked(st State) bool {
	if s.state == st {
		return false
	}
	s.log.Info("emacs state", "from", s.state, "to", st, "pid", s.pid)
	s.state = st
	return true
}

// Hello records a connected Emacs.
func (s *Supervisor) Hello(pid int) {
	s.mu.Lock()
	s.gen++
	s.connected, s.bye, s.misses = true, false, 0
	if s.restarting && (pid <= 0 || pid != s.oldPID) {
		s.restarting, s.err = false, ""
	}
	s.pid = pid
	if !s.restarting {
		s.setLocked(Online)
	}
	s.mu.Unlock()
	s.changed()
}

// Bye records that the coming disconnect is intentional.
func (s *Supervisor) Bye() {
	s.mu.Lock()
	s.bye = true
	s.mu.Unlock()
}

// Gone records the end of the connection and starts watching the process.
func (s *Supervisor) Gone() {
	s.mu.Lock()
	s.connected = false
	s.gen++
	if s.restarting {
		s.mu.Unlock()
		return
	}
	s.setLocked(Disconnected)
	if s.pid > 0 {
		go s.watch(s.gen, s.pid)
	}
	s.mu.Unlock()
	s.changed()
}

// watch polls pid until it exits or gen moves on.
func (s *Supervisor) watch(gen, pid int) {
	t := time.NewTicker(s.opts.Poll)
	defer t.Stop()
	for {
		select {
		case <-s.ctx.Done():
			return
		case <-t.C:
		}
		if s.opts.Alive(pid) {
			s.mu.Lock()
			stale := s.gen != gen
			s.mu.Unlock()
			if stale {
				return
			}
			continue
		}
		s.mu.Lock()
		if s.gen != gen {
			s.mu.Unlock()
			return
		}
		s.gen++
		if s.bye {
			s.setLocked(Stopped)
			s.mu.Unlock()
			s.changed()
			return
		}
		s.crashedLocked()
		return
	}
}

// crashedLocked records a crash and restarts Emacs unless crashes come too fast; it unlocks s.mu.
func (s *Supervisor) crashedLocked() {
	now := time.Now()
	s.total++
	s.lastCrash = now
	kept := s.crashes[:0]
	for _, t := range s.crashes {
		if now.Sub(t) < s.opts.CrashWindow {
			kept = append(kept, t)
		}
	}
	s.crashes = append(kept, now)
	s.log.Warn("emacs crashed", "pid", s.pid, "recent", len(s.crashes))
	switch {
	case len(s.opts.Start) == 0:
		s.err = ErrUnavailable.Error()
	case len(s.crashes) > s.opts.CrashLimit:
		s.err = fmt.Sprintf("Emacs crashed %d times within %s; not restarting it again", len(s.crashes), s.opts.CrashWindow)
	default:
		s.seq++
		s.restarting, s.oldPID, s.err = true, s.pid, ""
		s.setLocked(Restarting)
		seq := s.seq
		s.mu.Unlock()
		s.changed()
		go s.launch(seq)
		return
	}
	s.setLocked(Crashed)
	s.mu.Unlock()
	s.changed()
}

// Restart quits Emacs (asking first, then SIGTERM, then SIGKILL) and starts it again.
// It returns once the restart is under way.
func (s *Supervisor) Restart() error {
	s.mu.Lock()
	if len(s.opts.Start) == 0 {
		s.mu.Unlock()
		return ErrUnavailable
	}
	if s.restarting {
		s.mu.Unlock()
		return ErrBusy
	}
	s.gen++
	s.seq++
	s.restarting, s.oldPID, s.err = true, s.pid, ""
	s.setLocked(Restarting)
	seq, pid, connected := s.seq, s.pid, s.connected
	s.mu.Unlock()
	s.changed()
	go s.replace(seq, pid, connected)
	return nil
}

func (s *Supervisor) replace(seq, pid int, connected bool) {
	if connected && s.bridge != nil && s.bridge.Online() {
		ctx, cancel := context.WithTimeout(s.ctx, s.opts.PingTimeout)
		err := s.bridge.Call(ctx, MethodRestart, struct{}{}, nil)
		cancel()
		if err != nil {
			s.log.Warn("emacs did not take the restart request", "err", err)
		}
	}
	if pid > 0 && s.opts.Alive(pid) {
		steps := []struct {
			sig  syscall.Signal
			wait time.Duration
		}{{0, s.opts.QuitWait}, {syscall.SIGTERM, s.opts.TermWait}, {syscall.SIGKILL, s.opts.KillWait}}
		gone := false
		for _, step := range steps {
			if step.sig != 0 {
				s.log.Warn("emacs still running, signalling", "pid", pid, "signal", step.sig)
				if err := s.opts.Signal(pid, step.sig); err != nil && !errors.Is(err, syscall.ESRCH) {
					s.log.Warn("signalling emacs", "err", err)
				}
			}
			if gone = s.waitExit(pid, step.wait); gone {
				break
			}
		}
		if !gone {
			s.fail(seq, fmt.Sprintf("Emacs (pid %d) did not quit", pid), Disconnected)
			return
		}
	}
	s.launch(seq)
}

// waitExit reports whether pid exits within d.
func (s *Supervisor) waitExit(pid int, d time.Duration) bool {
	deadline := time.Now().Add(d)
	step := min(s.opts.Poll, 200*time.Millisecond)
	for {
		if !s.opts.Alive(pid) {
			return true
		}
		if time.Now().After(deadline) || s.ctx.Err() != nil {
			return false
		}
		time.Sleep(step)
	}
}

// launch starts Emacs after Settle and waits for it to connect.
func (s *Supervisor) launch(seq int) {
	select {
	case <-s.ctx.Done():
		return
	case <-time.After(s.opts.Settle):
	}
	if !s.current(seq) {
		return
	}
	ctx, cancel := context.WithTimeout(s.ctx, 30*time.Second)
	out, err := exec.CommandContext(ctx, s.opts.Start[0], s.opts.Start[1:]...).CombinedOutput()
	cancel()
	if err != nil {
		s.fail(seq, fmt.Sprintf("starting Emacs failed: %v %s", err, out), Stopped)
		return
	}
	s.log.Info("emacs started", "command", s.opts.Start)
	timer := time.NewTimer(s.opts.ConnectWait)
	defer timer.Stop()
	select {
	case <-s.ctx.Done():
	case <-timer.C:
		s.fail(seq, "Emacs was started but did not connect", Disconnected)
	}
}

// current reports whether restart seq is still under way.
func (s *Supervisor) current(seq int) bool {
	s.mu.Lock()
	defer s.mu.Unlock()
	return s.restarting && s.seq == seq
}

// fail ends restart seq with message, leaving state st.
func (s *Supervisor) fail(seq int, message string, st State) {
	s.mu.Lock()
	if !s.restarting || s.seq != seq {
		s.mu.Unlock()
		return
	}
	s.log.Warn("emacs restart failed", "err", message)
	s.restarting, s.err = false, message
	s.gen++
	s.setLocked(st)
	s.mu.Unlock()
	s.changed()
}

// Run pings Emacs until ctx ends; after it ends nothing is launched.
func (s *Supervisor) Run(ctx context.Context) {
	defer s.cancel()
	t := time.NewTicker(s.opts.PingEvery)
	defer t.Stop()
	for {
		select {
		case <-ctx.Done():
			return
		case <-t.C:
		}
		s.mu.Lock()
		check := s.connected && !s.restarting
		gen := s.gen
		s.mu.Unlock()
		if !check || s.bridge == nil || !s.bridge.Online() {
			continue
		}
		pctx, cancel := context.WithTimeout(ctx, s.opts.PingTimeout)
		err := s.bridge.Ping(pctx)
		cancel()
		if ctx.Err() != nil {
			return
		}
		s.mu.Lock()
		if s.gen != gen || !s.connected || s.restarting {
			s.mu.Unlock()
			continue
		}
		changed := false
		if err == nil {
			s.misses = 0
			changed = s.setLocked(Online)
		} else {
			s.misses++
			if s.misses >= s.opts.Misses {
				changed = s.setLocked(Unresponsive)
			}
		}
		s.mu.Unlock()
		if changed {
			s.changed()
		}
	}
}
