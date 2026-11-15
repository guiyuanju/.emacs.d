package awake

import (
	"errors"
	"fmt"
	"os"
	"path/filepath"
	"strconv"
	"strings"
	"sync/atomic"
	"syscall"
	"testing"
	"time"
)

// FakeCaffeinate writes a script into dir that records its arguments and pid in dir, then sleeps.
func FakeCaffeinate(t *testing.T, dir string) string {
	t.Helper()
	path := filepath.Join(dir, "caffeinate")
	script := fmt.Sprintf("#!/bin/sh\necho \"$@\" >%[1]s/args\necho $$ >%[1]s/pid.tmp\nmv %[1]s/pid.tmp %[1]s/pid\nexec sleep 600\n", dir)
	if err := os.WriteFile(path, []byte(script), 0o755); err != nil {
		t.Fatal(err)
	}
	return path
}

func waitFor(t *testing.T, what string, ok func() bool) {
	t.Helper()
	deadline := time.Now().Add(5 * time.Second)
	for !ok() {
		if time.Now().After(deadline) {
			t.Fatalf("timed out waiting for %s", what)
		}
		time.Sleep(10 * time.Millisecond)
	}
}

func pidIn(dir string) int {
	b, _ := os.ReadFile(filepath.Join(dir, "pid"))
	n, _ := strconv.Atoi(strings.TrimSpace(string(b)))
	return n
}

func alive(pid int) bool { return pid > 0 && syscall.Kill(pid, 0) == nil }

func TestKeeper(t *testing.T) {
	dir := t.TempDir()
	var changes atomic.Int32
	k := New(FakeCaffeinate(t, dir), nil, func() { changes.Add(1) })
	k.Retry = 20 * time.Millisecond
	defer k.Close()

	if err := k.Set(true); err != nil {
		t.Fatal(err)
	}
	waitFor(t, "caffeinate to start", func() bool { return pidIn(dir) > 0 })
	first := pidIn(dir)
	args, _ := os.ReadFile(filepath.Join(dir, "args"))
	if want := fmt.Sprintf("-i -w %d\n", os.Getpid()); string(args) != want {
		t.Errorf("caffeinate args %q, want %q", args, want)
	}
	if !k.On() || !k.Held() || changes.Load() == 0 {
		t.Errorf("on %v held %v changes %d after Set(true)", k.On(), k.Held(), changes.Load())
	}

	// A caffeinate that dies while on is restarted.
	if err := syscall.Kill(first, syscall.SIGKILL); err != nil {
		t.Fatal(err)
	}
	waitFor(t, "a new caffeinate", func() bool { p := pidIn(dir); return p != first && alive(p) && k.Held() })

	second := pidIn(dir)
	if err := k.Set(false); err != nil {
		t.Fatal(err)
	}
	if k.On() || k.Held() {
		t.Errorf("on %v held %v after Set(false)", k.On(), k.Held())
	}
	waitFor(t, "caffeinate to be stopped", func() bool { return !alive(second) })
	time.Sleep(100 * time.Millisecond)
	if pidIn(dir) != second {
		t.Error("caffeinate was restarted while off")
	}
}

func TestCloseStopsForGood(t *testing.T) {
	dir := t.TempDir()
	k := New(FakeCaffeinate(t, dir), nil, nil)
	if err := k.Set(true); err != nil {
		t.Fatal(err)
	}
	waitFor(t, "caffeinate to start", func() bool { return pidIn(dir) > 0 })
	pid := pidIn(dir)
	k.Close()
	waitFor(t, "caffeinate to be stopped", func() bool { return !alive(pid) })
	if err := k.Set(true); err != nil || k.Held() {
		t.Errorf("Set after Close: %v, held %v", err, k.Held())
	}
}

func TestUnavailable(t *testing.T) {
	k := New("", nil, nil)
	if err := k.Set(true); !errors.Is(err, ErrUnavailable) || k.On() {
		t.Errorf("Set(true) without caffeinate: %v, on %v", err, k.On())
	}
	if err := k.Set(false); err != nil {
		t.Error(err)
	}
}

func TestMissingCommandRetries(t *testing.T) {
	dir := t.TempDir()
	path := filepath.Join(dir, "later")
	k := New(path, nil, nil)
	k.Retry = 20 * time.Millisecond
	defer k.Close()
	if err := k.Set(true); err == nil {
		t.Fatal("starting a missing command succeeded")
	}
	if err := os.Rename(FakeCaffeinate(t, dir), path); err != nil {
		t.Fatal(err)
	}
	waitFor(t, "the retry to start caffeinate", func() bool { return k.Held() && alive(pidIn(dir)) })
}
