package settings

import (
	"os"
	"path/filepath"
	"testing"
)

func TestRoundTrip(t *testing.T) {
	path := filepath.Join(t.TempDir(), "d", "settings.json")
	s, err := Load(path)
	if err != nil || s != Default || !s.Awake {
		t.Fatalf("missing file: %+v, %v; want the default", s, err)
	}
	if err := Write(path, Settings{Awake: false}); err != nil {
		t.Fatal(err)
	}
	fi, err := os.Stat(path)
	if err != nil || fi.Mode().Perm() != 0o600 {
		t.Fatalf("mode %v, %v; want 0600", fi.Mode(), err)
	}
	if s, err := Load(path); err != nil || s.Awake {
		t.Fatalf("Load = %+v, %v; want awake off", s, err)
	}
	if err := os.WriteFile(path, []byte("{"), 0o600); err != nil {
		t.Fatal(err)
	}
	if s, err := Load(path); err == nil || s != Default {
		t.Fatalf("corrupt file: %+v, %v; want the default and an error", s, err)
	}
}
