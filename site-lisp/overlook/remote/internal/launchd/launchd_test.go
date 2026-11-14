package launchd

import (
	"errors"
	"runtime"
	"syscall"
	"testing"
)

func TestName(t *testing.T) {
	for addr, want := range map[string]string{"launchd:http": "http", "launchd:": "", "127.0.0.1:8767": ""} {
		if got, ok := Name(addr); got != want || ok != (want != "") {
			t.Errorf("Name(%q) = %q, %v", addr, got, ok)
		}
	}
}

// Outside a launchd job the call must fail cleanly, which also exercises the libSystem trampoline.
func TestOutsideLaunchd(t *testing.T) {
	_, err := Listeners("overlook-test-none")
	if err == nil {
		t.Fatal("got sockets outside launchd")
	}
	if runtime.GOOS == "darwin" {
		var errno syscall.Errno
		if !errors.As(err, &errno) {
			t.Fatalf("not an errno: %v", err)
		}
		t.Logf("outside launchd: %v (%d)", err, int(errno))
	}
}
