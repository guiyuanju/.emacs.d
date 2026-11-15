// Package awake keeps the Mac from idle sleeping while the daemon runs, with caffeinate(8).
//
// caffeinate -i -w <daemon pid> holds the assertion and exits by itself when the daemon dies,
// so a crash never leaves the Mac awake.
package awake

import (
	"errors"
	"log/slog"
	"os"
	"os/exec"
	"strconv"
	"sync"
	"time"
)

// ErrUnavailable is returned when keeping awake is asked for without a caffeinate command.
var ErrUnavailable = errors.New("awake: no caffeinate command configured")

// Keeper runs caffeinate while it is on, restarting it if it dies.
type Keeper struct {
	path    string
	log     *slog.Logger
	changed func()
	// Retry is the delay before restarting a caffeinate that exited while on.
	Retry time.Duration

	mu     sync.Mutex
	on     bool
	closed bool
	cmd    *exec.Cmd
	timer  *time.Timer
}

// New returns a Keeper running path (empty: never keeps awake); changed is called whenever On or Held may have changed.
func New(path string, log *slog.Logger, changed func()) *Keeper {
	if log == nil {
		log = slog.New(slog.DiscardHandler)
	}
	if changed == nil {
		changed = func() {}
	}
	return &Keeper{path: path, log: log, changed: changed, Retry: time.Second}
}

// Set turns keeping awake on or off.
func (k *Keeper) Set(on bool) error {
	if on && k.path == "" {
		return ErrUnavailable
	}
	k.mu.Lock()
	if k.closed || k.on == on {
		k.mu.Unlock()
		return nil
	}
	k.on = on
	var err error
	if on {
		err = k.spawnLocked()
	} else {
		k.stopLocked()
	}
	k.mu.Unlock()
	k.changed()
	return err
}

// On reports whether keeping awake is turned on.
func (k *Keeper) On() bool {
	k.mu.Lock()
	defer k.mu.Unlock()
	return k.on
}

// Held reports whether caffeinate is running now.
func (k *Keeper) Held() bool {
	k.mu.Lock()
	defer k.mu.Unlock()
	return k.cmd != nil
}

// Close stops caffeinate for good.
func (k *Keeper) Close() {
	k.mu.Lock()
	k.closed = true
	k.stopLocked()
	k.mu.Unlock()
}

func (k *Keeper) stopLocked() {
	if k.timer != nil {
		k.timer.Stop()
		k.timer = nil
	}
	if k.cmd != nil {
		_ = k.cmd.Process.Kill()
		k.cmd = nil
	}
}

func (k *Keeper) spawnLocked() error {
	cmd := exec.Command(k.path, "-i", "-w", strconv.Itoa(os.Getpid()))
	if err := cmd.Start(); err != nil {
		k.log.Error("keep awake: starting caffeinate", "path", k.path, "err", err)
		k.retryLocked()
		return err
	}
	k.cmd = cmd
	k.log.Info("keeping the Mac awake", "caffeinate", cmd.Process.Pid)
	go k.wait(cmd)
	return nil
}

func (k *Keeper) retryLocked() {
	k.timer = time.AfterFunc(k.Retry, func() {
		k.mu.Lock()
		k.timer = nil
		if k.on && !k.closed && k.cmd == nil {
			_ = k.spawnLocked()
		}
		k.mu.Unlock()
		k.changed()
	})
}

func (k *Keeper) wait(cmd *exec.Cmd) {
	err := cmd.Wait()
	k.mu.Lock()
	if k.cmd != cmd {
		k.mu.Unlock()
		return
	}
	k.cmd = nil
	if k.on && !k.closed {
		k.log.Warn("keep awake: caffeinate exited; restarting", "err", err)
		k.retryLocked()
	}
	k.mu.Unlock()
	k.changed()
}
