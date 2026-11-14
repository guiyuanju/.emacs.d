// Package auth checks the Bearer token kept in the token file shared with the old server.
package auth

import (
	"bytes"
	"crypto/subtle"
	"net/http"
	"os"
	"strings"
	"sync"
	"time"
)

// RecheckEvery bounds how often the token file's mtime is looked at.
const RecheckEvery = time.Second

// Tokens holds the current token, re-read when the file changes.
type Tokens struct {
	path    string
	mu      sync.Mutex
	token   []byte
	mtime   time.Time
	size    int64
	checked time.Time
	now     func() time.Time
}

// NewTokens returns tokens backed by path; the file must exist.
func NewTokens(path string) (*Tokens, error) {
	t := &Tokens{path: path, now: time.Now}
	fi, err := os.Stat(path)
	if err != nil {
		return nil, err
	}
	if err := t.load(fi); err != nil {
		return nil, err
	}
	t.checked = t.now()
	return t, nil
}

func (t *Tokens) load(fi os.FileInfo) error {
	data, err := os.ReadFile(t.path)
	if err != nil {
		return err
	}
	t.token = bytes.TrimSpace(data)
	t.mtime, t.size = fi.ModTime(), fi.Size()
	return nil
}

func (t *Tokens) current() []byte {
	t.mu.Lock()
	defer t.mu.Unlock()
	if now := t.now(); now.Sub(t.checked) >= RecheckEvery {
		t.checked = now
		if fi, err := os.Stat(t.path); err == nil && (!fi.ModTime().Equal(t.mtime) || fi.Size() != t.size) {
			_ = t.load(fi)
		}
	}
	return t.token
}

// Valid reports whether presented is the current token, in constant time.
func (t *Tokens) Valid(presented string) bool {
	token := t.current()
	return len(token) > 0 && subtle.ConstantTimeCompare([]byte(presented), token) == 1
}

// Require passes requests carrying "Authorization: Bearer <token>" to next, others to deny.
func Require(t *Tokens, deny http.Handler) func(http.Handler) http.Handler {
	return func(next http.Handler) http.Handler {
		return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
			presented, ok := strings.CutPrefix(r.Header.Get("Authorization"), "Bearer ")
			if !ok || !t.Valid(strings.TrimSpace(presented)) {
				deny.ServeHTTP(w, r)
				return
			}
			next.ServeHTTP(w, r)
		})
	}
}
