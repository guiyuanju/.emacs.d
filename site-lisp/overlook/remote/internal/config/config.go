// Package config parses overlook-remoted's flags.
package config

import (
	"errors"
	"flag"
	"fmt"
	"io"
	"os"
	"path/filepath"
	"runtime"
	"slices"
	"strings"
	"time"

	"github.com/guiyuanju/overlook/remote/internal/launchd"
)

// DefaultListen is the development address; launchd passes the production one.
const DefaultListen = "127.0.0.1:8767"

// Config is the daemon's configuration.
type Config struct {
	Listen            []string
	ListenTLS         []string
	TLSCert           string
	TLSKey            string
	TokenFile         string
	Socket            string
	AutoClose         time.Duration
	StreamCompression bool
	Debug             bool
	// WebDir serves the page from disk, picking up edits; empty serves the embedded page.
	WebDir string
	// CacheDir keeps compressed page files across restarts; empty disables it.
	CacheDir string
	// StateFile carries derived state across restarts; empty disables it.
	StateFile string
	// AdminSocket is the control socket for local tools; empty disables it.
	AdminSocket string
	// SettingsFile keeps user settings such as keep-awake across restarts; empty keeps them in memory.
	SettingsFile string
	// Caffeinate is the caffeinate(8) command that keeps the Mac awake; empty never keeps it awake.
	Caffeinate string
	// EmacsStart is the command, split on spaces, that starts Emacs after a crash or on request; empty never starts it.
	EmacsStart []string
	// FakeEmacs is a fixtures directory replayed by an in-process fake Emacs, for browser tests.
	FakeEmacs     string
	FakeSpeed     float64
	FakeLiveDelay time.Duration
	FakeResume    bool
}

type listFlag []string

func (l *listFlag) String() string { return strings.Join(*l, ",") }

func (l *listFlag) Set(v string) error {
	*l = append(*l, v)
	return nil
}

// DefaultSocket is ${XDG_RUNTIME_DIR:-$HOME/.local/state}/overlook-remote/bridge.sock.
func DefaultSocket() string {
	base := os.Getenv("XDG_RUNTIME_DIR")
	if base == "" {
		home, _ := os.UserHomeDir()
		base = filepath.Join(home, ".local", "state")
	}
	return filepath.Join(base, "overlook-remote", "bridge.sock")
}

// DefaultCacheDir is the user cache directory's overlook-remoted, or "" when there is none.
func DefaultCacheDir() string {
	dir, err := os.UserCacheDir()
	if err != nil {
		return ""
	}
	return filepath.Join(dir, "overlook-remoted")
}

// DefaultCaffeinate is caffeinate(8) on macOS and nothing elsewhere.
func DefaultCaffeinate() string {
	if runtime.GOOS == "darwin" {
		return "/usr/bin/caffeinate"
	}
	return ""
}

// AdminSocketBeside is the default admin socket for the bridge socket path.
func AdminSocketBeside(socket string) string {
	return filepath.Join(filepath.Dir(socket), "admin.sock")
}

// Parse reads args (without the program name); output receives usage and errors.
func Parse(args []string, output io.Writer) (Config, error) {
	var c Config
	var listen, listenTLS listFlag
	var minutes int
	fs := flag.NewFlagSet("overlook-remoted", flag.ContinueOnError)
	fs.SetOutput(output)
	fs.Var(&listen, "listen", "plain HTTP `address` or launchd:<socket name> (repeatable; default "+DefaultListen+")")
	fs.Var(&listenTLS, "listen-tls", "HTTPS `address` or launchd:<socket name> (repeatable; needs -tls-cert and -tls-key)")
	fs.StringVar(&c.TLSCert, "tls-cert", "", "TLS certificate `file` (e.g. from tailscale cert)")
	fs.StringVar(&c.TLSKey, "tls-key", "", "TLS key `file`")
	fs.StringVar(&c.TokenFile, "token-file", "", "`file` holding the Bearer token (required; shared with Emacs)")
	fs.StringVar(&c.Socket, "socket", DefaultSocket(), "bridge unix socket `path`")
	fs.IntVar(&minutes, "auto-close", 0, "close non-loopback listeners after `minutes` (0 never)")
	fs.BoolVar(&c.StreamCompression, "stream-compression", true, "gzip the event stream when the client accepts it")
	fs.BoolVar(&c.Debug, "debug", false, "log at debug level")
	fs.StringVar(&c.WebDir, "web-dir", "", "serve the page from this `dir` (remote/web), reloading it when files change")
	fs.StringVar(&c.CacheDir, "cache-dir", DefaultCacheDir(), "keep compressed page files in this `dir` (empty: none)")
	fs.StringVar(&c.StateFile, "state-file", "", "keep state across restarts in this `file` (default state.json beside -socket; empty: none)")
	fs.StringVar(&c.AdminSocket, "admin-socket", "", "control socket `path` for the menu bar app (default admin.sock beside -socket; empty: none)")
	fs.StringVar(&c.SettingsFile, "settings-file", "", "keep settings such as keep-awake in this `file` (default settings.json beside -socket; empty: none)")
	fs.StringVar(&c.Caffeinate, "caffeinate", DefaultCaffeinate(), "caffeinate `command` that keeps the Mac awake (empty: never)")
	var emacsStart string
	fs.StringVar(&emacsStart, "emacs-start", "", "`command` (split on spaces) that starts Emacs after a crash or on request, e.g. \"/usr/bin/open -a Emacs\" (empty: never)")
	fs.StringVar(&c.FakeEmacs, "fake-emacs", "", "replay the fixtures `dir` as a fake Emacs (tests only; SIGUSR1 replays live.ndjson)")
	fs.Float64Var(&c.FakeSpeed, "fake-speed", 1, "speed factor of the fake Emacs's live steps")
	fs.DurationVar(&c.FakeLiveDelay, "fake-live-delay", time.Second, "wait before the fake Emacs plays live steps (negative: only on SIGUSR1)")
	fs.BoolVar(&c.FakeResume, "fake-resume", false, "the fake Emacs reconnects with nothing buffered: no events.ndjson replay")
	if err := fs.Parse(args); err != nil {
		return Config{}, err
	}
	if fs.NArg() > 0 {
		return Config{}, fmt.Errorf("unexpected argument %q", fs.Arg(0))
	}
	set := map[string]bool{}
	fs.Visit(func(f *flag.Flag) { set[f.Name] = true })
	if !set["state-file"] {
		c.StateFile = filepath.Join(filepath.Dir(c.Socket), "state.json")
	}
	if !set["admin-socket"] {
		c.AdminSocket = AdminSocketBeside(c.Socket)
	}
	if !set["settings-file"] {
		c.SettingsFile = filepath.Join(filepath.Dir(c.Socket), "settings.json")
	}
	c.Listen, c.ListenTLS = listen, listenTLS
	c.EmacsStart = strings.Fields(emacsStart)
	if len(c.Listen) == 0 && len(c.ListenTLS) == 0 {
		c.Listen = []string{DefaultListen}
	}
	if minutes < 0 {
		return Config{}, errors.New("-auto-close must not be negative")
	}
	c.AutoClose = time.Duration(minutes) * time.Minute
	if c.AutoClose > 0 {
		for _, a := range append(slices.Clone(c.Listen), c.ListenTLS...) {
			if strings.HasPrefix(a, launchd.Prefix) {
				return Config{}, fmt.Errorf("-auto-close cannot close %s: launchd keeps its sockets open", a)
			}
		}
	}
	if c.TokenFile == "" {
		return Config{}, errors.New("-token-file is required")
	}
	if len(c.ListenTLS) > 0 && (c.TLSCert == "" || c.TLSKey == "") {
		return Config{}, errors.New("-listen-tls needs -tls-cert and -tls-key")
	}
	return c, nil
}
