package admin

import (
	"bufio"
	"context"
	"errors"
	"net"
	"os"
	"path/filepath"
	"strings"
	"sync"
	"testing"
	"time"

	"github.com/guiyuanju/overlook/remote/internal/supervisor"
)

type fakeDaemon struct {
	mu sync.Mutex
	st Status
}

func (f *fakeDaemon) Status() Status {
	f.mu.Lock()
	defer f.mu.Unlock()
	return f.st
}

func (f *fakeDaemon) SetAwake(on bool) error {
	f.mu.Lock()
	defer f.mu.Unlock()
	if f.st.Daemon == "no-caffeinate" {
		return errors.New("unavailable")
	}
	f.st.Awake = on
	return nil
}

func (f *fakeDaemon) RestartEmacs() error {
	f.mu.Lock()
	defer f.mu.Unlock()
	if f.st.EmacsProcess == nil {
		return errors.New("not supervised")
	}
	f.st.EmacsProcess.State = "restarting"
	return nil
}

func (f *fakeDaemon) update(fn func(*Status)) {
	f.mu.Lock()
	fn(&f.st)
	f.mu.Unlock()
}

// shortDir is a temporary directory whose socket paths fit the 104-byte limit.
func shortDir(t *testing.T) string {
	dir, err := os.MkdirTemp("/tmp", "adm")
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { os.RemoveAll(dir) })
	return dir
}

func serve(t *testing.T, d Daemon) (*Server, string, context.CancelFunc) {
	t.Helper()
	path := filepath.Join(shortDir(t), "s", "admin.sock")
	s := NewServer(path, d, nil)
	if err := s.Listen(); err != nil {
		t.Fatal(err)
	}
	ctx, cancel := context.WithCancel(context.Background())
	done := make(chan error, 1)
	go func() { done <- s.Serve(ctx) }()
	t.Cleanup(func() {
		cancel()
		if err := <-done; err != nil {
			t.Error(err)
		}
	})
	return s, path, cancel
}

func TestStatusAndSetAwake(t *testing.T) {
	d := &fakeDaemon{st: Status{Daemon: "v1", Emacs: "online", Awake: true, Port: 8766, Host: "100.64.0.1", Scheme: "http"}}
	_, path, _ := serve(t, d)

	fi, err := os.Stat(path)
	if err != nil || fi.Mode().Perm() != 0o600 {
		t.Fatalf("socket mode %v, %v", fi.Mode(), err)
	}
	if di, _ := os.Stat(filepath.Dir(path)); di.Mode().Perm() != 0o700 {
		t.Fatalf("directory mode %v", di.Mode())
	}

	st, err := Do(path, (*Client).Status)
	if err != nil || st.Daemon != "v1" || st.Emacs != "online" || st.Port != 8766 || !st.Awake {
		t.Fatalf("status %+v, %v", st, err)
	}
	st, err = Do(path, func(c *Client) (Status, error) { return c.SetAwake(false) })
	if err != nil || st.Awake {
		t.Fatalf("set-awake off: %+v, %v", st, err)
	}
	if d.Status().Awake {
		t.Fatal("the daemon still keeps awake")
	}
	d.update(func(s *Status) { s.Daemon = "no-caffeinate" })
	if _, err := Do(path, func(c *Client) (Status, error) { return c.SetAwake(true) }); err == nil || err.Error() != "unavailable" {
		t.Fatalf("set-awake error: %v", err)
	}
}

func TestRestartEmacs(t *testing.T) {
	d := &fakeDaemon{st: Status{Daemon: "v1"}}
	_, path, _ := serve(t, d)
	if _, err := Do(path, (*Client).RestartEmacs); err == nil || err.Error() != "not supervised" {
		t.Fatalf("restart without supervision: %v", err)
	}
	d.update(func(s *Status) { s.EmacsProcess = &supervisor.Status{State: supervisor.Online, CanRestart: true} })
	st, err := Do(path, (*Client).RestartEmacs)
	if err != nil || st.EmacsProcess == nil || st.EmacsProcess.State != "restarting" {
		t.Fatalf("restart: %+v, %v", st, err)
	}
}

func TestBadRequests(t *testing.T) {
	_, path, _ := serve(t, &fakeDaemon{})
	c, err := net.Dial("unix", path)
	if err != nil {
		t.Fatal(err)
	}
	defer c.Close()
	r := bufio.NewReader(c)
	for _, tc := range []struct{ req, want string }{
		{"not json", `"error":"bad request`},
		{`{"op":"reboot"}`, `"error":"unknown op \"reboot\""`},
		{`{"op":"set-awake"}`, `"error":"set-awake needs \"on\""`},
		{`{"op":"status"}`, `"status":{`},
	} {
		if _, err := c.Write([]byte(tc.req + "\n")); err != nil {
			t.Fatal(err)
		}
		line, err := r.ReadString('\n')
		if err != nil || !strings.Contains(line, tc.want) {
			t.Errorf("%s: got %q, %v; want %s", tc.req, line, err, tc.want)
		}
	}
}

func TestWatch(t *testing.T) {
	d := &fakeDaemon{st: Status{Daemon: "v1", Emacs: "offline"}}
	s, path, _ := serve(t, d)
	ctx, cancel := context.WithCancel(context.Background())
	got := make(chan Status, 16)
	done := make(chan error, 1)
	go func() { done <- Watch(ctx, path, func(st Status) { got <- st }) }()
	next := func() Status {
		t.Helper()
		select {
		case st := <-got:
			return st
		case <-time.After(5 * time.Second):
			t.Fatal("no status pushed")
			return Status{}
		}
	}
	if st := next(); st.Emacs != "offline" {
		t.Fatalf("first push %+v", st)
	}

	// Uptime alone is no change; Emacs coming online is.
	d.update(func(s *Status) { s.Uptime = 42 })
	s.Changed()
	d.update(func(s *Status) { s.Emacs, s.Streams = "online", 2 })
	s.Changed()
	if st := next(); st.Emacs != "online" || st.Streams != 2 {
		t.Fatalf("second push %+v", st)
	}
	select {
	case st := <-got:
		t.Fatalf("unexpected push %+v", st)
	case <-time.After(50 * time.Millisecond):
	}

	cancel()
	if err := <-done; !errors.Is(err, context.Canceled) {
		t.Fatalf("Watch returned %v", err)
	}
}

func TestShutdownEndsWatchersAndRemovesSocket(t *testing.T) {
	_, path, stop := serve(t, &fakeDaemon{})
	done := make(chan error, 1)
	go func() { done <- Watch(context.Background(), path, func(Status) {}) }()
	time.Sleep(50 * time.Millisecond)
	stop()
	select {
	case err := <-done:
		if err == nil {
			t.Error("Watch ended without an error when the daemon went away")
		}
	case <-time.After(5 * time.Second):
		t.Fatal("watcher not closed at shutdown")
	}
	deadline := time.Now().Add(2 * time.Second)
	for {
		if _, err := os.Lstat(path); errors.Is(err, os.ErrNotExist) {
			break
		}
		if time.Now().After(deadline) {
			t.Fatal("socket left behind")
		}
		time.Sleep(10 * time.Millisecond)
	}
}

func TestListenReplacesStaleSocketButNotALiveOne(t *testing.T) {
	_, path, _ := serve(t, &fakeDaemon{})
	if err := NewServer(path, &fakeDaemon{}, nil).Listen(); err == nil || !strings.Contains(err.Error(), "in use") {
		t.Fatalf("second Listen on a live socket: %v", err)
	}
	stale := filepath.Join(shortDir(t), "stale.sock")
	ln, err := net.Listen("unix", stale)
	if err != nil {
		t.Fatal(err)
	}
	ln.(*net.UnixListener).SetUnlinkOnClose(false)
	ln.Close()
	s := NewServer(stale, &fakeDaemon{}, nil)
	if err := s.Listen(); err != nil {
		t.Fatalf("Listen over a stale socket: %v", err)
	}
	s.ln.Close()
}

func TestNilServerChanged(t *testing.T) {
	var s *Server
	s.Changed()
}
