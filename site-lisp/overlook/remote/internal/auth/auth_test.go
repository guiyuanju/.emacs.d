package auth

import (
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"testing"
	"time"
)

func TestRequire(t *testing.T) {
	path := filepath.Join(t.TempDir(), "token")
	if err := os.WriteFile(path, []byte("secret\n"), 0o600); err != nil {
		t.Fatal(err)
	}
	tokens, err := NewTokens(path)
	if err != nil {
		t.Fatal(err)
	}
	clock := time.Now()
	tokens.now = func() time.Time { return clock }
	deny := http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) { w.WriteHeader(http.StatusUnauthorized) })
	ok := http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) { w.WriteHeader(http.StatusNoContent) })
	h := Require(tokens, deny)(ok)
	status := func(header string) int {
		r := httptest.NewRequest("GET", "/", nil)
		if header != "" {
			r.Header.Set("Authorization", header)
		}
		w := httptest.NewRecorder()
		h.ServeHTTP(w, r)
		return w.Code
	}
	tests := []struct {
		header string
		want   int
	}{
		{"Bearer secret", 204},
		{"Bearer wrong", 401},
		{"Bearer ", 401},
		{"secret", 401},
		{"", 401},
		{"Basic secret", 401},
	}
	for _, tt := range tests {
		if got := status(tt.header); got != tt.want {
			t.Errorf("%q: got %d, want %d", tt.header, got, tt.want)
		}
	}

	if err := os.WriteFile(path, []byte("rotated-token\n"), 0o600); err != nil {
		t.Fatal(err)
	}
	if got := status("Bearer secret"); got != 204 {
		t.Errorf("old token rejected before the recheck interval: %d", got)
	}
	clock = clock.Add(RecheckEvery)
	if got := status("Bearer rotated-token"); got != 204 {
		t.Errorf("rotated token: %d", got)
	}
	if got := status("Bearer secret"); got != 401 {
		t.Errorf("old token after rotation: %d", got)
	}
}

func TestEmptyTokenRejectsAll(t *testing.T) {
	path := filepath.Join(t.TempDir(), "token")
	_ = os.WriteFile(path, []byte("\n"), 0o600)
	tokens, err := NewTokens(path)
	if err != nil {
		t.Fatal(err)
	}
	if tokens.Valid("") {
		t.Fatal("empty token accepted")
	}
	if _, err := NewTokens(filepath.Join(t.TempDir(), "missing")); err == nil {
		t.Fatal("missing file accepted")
	}
}
