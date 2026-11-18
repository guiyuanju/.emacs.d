// Package usage imports numeric consumption from local CLI logs, independently of chat retention.
package usage

import (
	"context"
	"crypto/sha256"
	"database/sql"
	"encoding/hex"
	"errors"
	"os"
	"path/filepath"
	"strings"
	"sync"
	"time"
)

type Tokens struct {
	Input      int64 `json:"input"`
	CacheRead  int64 `json:"cacheRead"`
	CacheWrite int64 `json:"cacheWrite"`
	Output     int64 `json:"output"`
}

func (t Tokens) Total() int64 { return t.Input + t.CacheRead + t.CacheWrite + t.Output }
func (t *Tokens) Add(v Tokens) {
	t.Input += v.Input
	t.CacheRead += v.CacheRead
	t.CacheWrite += v.CacheWrite
	t.Output += v.Output
}
func (t Tokens) valid() bool {
	return t.Input >= 0 && t.CacheRead >= 0 && t.CacheWrite >= 0 && t.Output >= 0
}

type Event struct {
	ID       string    `json:"id"`
	At       time.Time `json:"at"`
	Provider string    `json:"provider"`
	Session  string    `json:"session"`
	Model    string    `json:"model,omitempty"`
	Root     string    `json:"root,omitempty"`
	Project  string    `json:"project,omitempty"`
	Tokens   Tokens    `json:"tokens"`
}

type fileState struct {
	Identity string `json:"identity,omitempty"`
	Prefix   string `json:"prefix,omitempty"`
	Anchor   string `json:"anchor,omitempty"`
	Offset   int64  `json:"offset"`
	Size     int64  `json:"size"`
	Mtime    int64  `json:"mtime"`
	Session  string `json:"session"`
	Root     string `json:"root"`
	Model    string `json:"model"`
	Previous Tokens `json:"previous"`
	Invalid  bool   `json:"invalid,omitempty"`
}

type disk struct {
	Format  int                  `json:"format"`
	Events  map[string]Event     `json:"events"`
	Files   map[string]fileState `json:"files"`
	Updated time.Time            `json:"updated"`
}

type Source struct{ Provider, Dir string }
type Options struct {
	Path       string
	LegacyPath string
	Sources    []Source
	// Project resolves a working directory to the project known by Emacs.
	Project func(string) string
}

type Ledger struct {
	mu         sync.RWMutex
	scanMu     sync.Mutex
	opts       Options
	db         *sql.DB
	tempDir    string
	updated    time.Time
	revision   uint64
	reports    map[reportKey]Report
	flights    map[flightKey]*reportFlight
	ready      bool
	scanErrors int
	lastError  string
	disabled   bool
}

// Unavailable preserves the existing ledger after an open failure, while the remote stays usable.
func Unavailable(message string) *Ledger {
	return &Ledger{disabled: true, lastError: message}
}

func DefaultSources(home string) []Source {
	claude := os.Getenv("CLAUDE_CONFIG_DIR")
	if claude == "" {
		claude = filepath.Join(home, ".claude")
	}
	codex := os.Getenv("CODEX_HOME")
	if codex == "" {
		codex = filepath.Join(home, ".codex")
	}
	return []Source{{"claude", filepath.Join(claude, "projects")}, {"codex", filepath.Join(codex, "sessions")}, {"codex", filepath.Join(codex, "archived_sessions")}}
}

// Run scans immediately, then checks for appended records once a minute.
func (l *Ledger) Run(ctx context.Context) {
	if l.disabled {
		return
	}
	l.Scan(ctx)
	tick := time.NewTicker(time.Minute)
	defer tick.Stop()
	for {
		select {
		case <-ctx.Done():
			return
		case <-tick.C:
			l.Scan(ctx)
		}
	}
}

func (l *Ledger) Scan(ctx context.Context) {
	l.scanMu.Lock()
	defer l.scanMu.Unlock()
	failures := 0
	resolve := l.projectResolver()
	for _, src := range l.opts.Sources {
		err := filepath.WalkDir(src.Dir, func(path string, d os.DirEntry, err error) error {
			if ctx.Err() != nil {
				return ctx.Err()
			}
			if err != nil {
				if !errors.Is(err, os.ErrNotExist) {
					failures++
				}
				return nil
			}
			if d.IsDir() || !strings.HasSuffix(path, ".jsonl") {
				return nil
			}
			if err := l.importFile(ctx, path, src.Provider, resolve); err != nil {
				failures++
			}
			return nil
		})
		if err != nil && ctx.Err() == nil {
			failures++
		}
	}
	l.mu.Lock()
	l.ready = ctx.Err() == nil
	l.scanErrors = failures
	l.updated = time.Now().UTC()
	l.mu.Unlock()
}

func eventID(provider, session, id string) string {
	sum := sha256.Sum256([]byte(provider + "\x00" + session + "\x00" + id))
	return hex.EncodeToString(sum[:])
}
