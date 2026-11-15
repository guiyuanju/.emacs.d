package main

import (
	"context"
	"fmt"
	"os"
	"path/filepath"
	"strconv"
	"strings"
	"syscall"
	"testing"
	"time"

	"github.com/guiyuanju/overlook/remote/internal/admin"
	"github.com/guiyuanju/overlook/remote/internal/settings"
)

// fakeCaffeinate writes a script into dir that records its arguments and pid there, then sleeps.
func fakeCaffeinate(t *testing.T, dir string) string {
	t.Helper()
	path := filepath.Join(dir, "caffeinate")
	script := fmt.Sprintf("#!/bin/sh\necho \"$@\" >%[1]s/args\necho $$ >%[1]s/pid.tmp\nmv %[1]s/pid.tmp %[1]s/pid\nexec sleep 600\n", dir)
	if err := os.WriteFile(path, []byte(script), 0o755); err != nil {
		t.Fatal(err)
	}
	return path
}

func caffeinatePid(dir string) int {
	b, _ := os.ReadFile(filepath.Join(dir, "pid"))
	n, _ := strconv.Atoi(strings.TrimSpace(string(b)))
	return n
}

func eventually(t *testing.T, what string, ok func() bool) {
	t.Helper()
	deadline := time.Now().Add(5 * time.Second)
	for !ok() {
		if time.Now().After(deadline) {
			t.Fatalf("timed out waiting for %s", what)
		}
		time.Sleep(10 * time.Millisecond)
	}
}

// TestAdminSocketAndKeepAwake drives the admin socket of a running daemon: status, watch and a keep-awake
// setting that survives a restart, with a fake caffeinate.
func TestAdminSocketAndKeepAwake(t *testing.T) {
	cfg := baseConfig(t)
	dir := filepath.Dir(cfg.Socket)
	caf := t.TempDir()
	cfg.AdminSocket = filepath.Join(dir, "admin.sock")
	cfg.SettingsFile = filepath.Join(dir, "settings.json")
	cfg.Caffeinate = fakeCaffeinate(t, caf)

	r := launch(t, cfg)
	r.waitOnline()
	eventually(t, "caffeinate to start", func() bool { return caffeinatePid(caf) > 0 })
	args, _ := os.ReadFile(filepath.Join(caf, "args"))
	if want := fmt.Sprintf("-i -w %d\n", os.Getpid()); string(args) != want {
		t.Errorf("caffeinate args %q, want %q", args, want)
	}

	st, err := admin.Do(cfg.AdminSocket, (*admin.Client).Status)
	if err != nil {
		t.Fatal(err)
	}
	_, port, _ := strings.Cut(strings.TrimPrefix(r.base, "http://"), ":")
	if st.Emacs != "online" || st.Streams != 0 || !st.Awake || !st.AwakeHeld || st.Scheme != "http" ||
		strconv.Itoa(st.Port) != port || len(st.Listeners) != 1 || !st.Listeners[0].Loopback || st.Daemon != version {
		t.Fatalf("status %+v", st)
	}

	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()
	pushed := make(chan admin.Status, 32)
	go func() { _ = admin.Watch(ctx, cfg.AdminSocket, func(s admin.Status) { pushed <- s }) }()
	waitPush := func(what string, ok func(admin.Status) bool) {
		t.Helper()
		deadline := time.After(5 * time.Second)
		for {
			select {
			case s := <-pushed:
				if ok(s) {
					return
				}
			case <-deadline:
				t.Fatalf("no push with %s", what)
			}
		}
	}
	waitPush("the first status", func(s admin.Status) bool { return s.Emacs == "online" })
	r.openStream("dashboard=")
	waitPush("an open stream", func(s admin.Status) bool { return s.Streams == 1 })

	first := caffeinatePid(caf)
	if _, err := admin.Do(cfg.AdminSocket, func(c *admin.Client) (admin.Status, error) { return c.SetAwake(false) }); err != nil {
		t.Fatal(err)
	}
	waitPush("keep-awake off", func(s admin.Status) bool { return !s.Awake && !s.AwakeHeld })
	eventually(t, "caffeinate to stop", func() bool { return syscall.Kill(first, 0) != nil })
	if s, err := settings.Load(cfg.SettingsFile); err != nil || s.Awake {
		t.Fatalf("settings %+v, %v", s, err)
	}
	cancel()
	r.stop()

	// The setting survives a restart.
	os.Remove(filepath.Join(caf, "pid"))
	r = launch(t, cfg)
	r.waitOnline()
	if st, err := admin.Do(cfg.AdminSocket, (*admin.Client).Status); err != nil || st.Awake {
		t.Fatalf("after restart: %+v, %v", st, err)
	}
	time.Sleep(100 * time.Millisecond)
	if caffeinatePid(caf) != 0 {
		t.Fatal("caffeinate started although keep-awake is off")
	}
	if st, err := admin.Do(cfg.AdminSocket, func(c *admin.Client) (admin.Status, error) { return c.SetAwake(true) }); err != nil || !st.Awake {
		t.Fatalf("set-awake on: %+v, %v", st, err)
	}
	eventually(t, "caffeinate to start again", func() bool { return caffeinatePid(caf) > 0 })
	again := caffeinatePid(caf)
	r.stop()
	eventually(t, "caffeinate to stop with the daemon", func() bool { return syscall.Kill(again, 0) != nil })
	if _, err := os.Lstat(cfg.AdminSocket); err == nil {
		t.Error("admin socket left behind after shutdown")
	}
}
