package state

import (
	"errors"
	"os"
	"path/filepath"
	"testing"

	"github.com/guiyuanju/overlook/remote/internal/store"
)

func TestWriteLoad(t *testing.T) {
	path := filepath.Join(t.TempDir(), "sub", "state.json")
	if _, err := Load(path); !errors.Is(err, os.ErrNotExist) {
		t.Fatalf("missing file: %v", err)
	}
	in := &File{Daemon: "test", Secret: []byte("0123456789abcdef0123456789abcdef"), Store: &store.Saved{EmacsEpoch: "e1", Seq: 7}}
	if err := Write(path, in); err != nil {
		t.Fatal(err)
	}
	if fi, err := os.Stat(path); err != nil || fi.Mode().Perm() != 0o600 {
		t.Fatalf("mode %v %v", fi.Mode(), err)
	}
	out, err := Load(path)
	if err != nil || out.Store.Seq != 7 || string(out.Secret) != string(in.Secret) || out.Format != Format {
		t.Fatalf("round trip %+v %v", out, err)
	}
	entries, _ := os.ReadDir(filepath.Dir(path))
	if len(entries) != 1 {
		t.Fatalf("temporary files left: %v", entries)
	}
}

func TestUnreadable(t *testing.T) {
	dir := t.TempDir()
	for name, content := range map[string]string{
		"garbage": "not json", "old": `{"format":0,"store":{}}`, "future": `{"format":99}`, "empty": `{"format":1}`,
	} {
		path := filepath.Join(dir, name)
		if err := os.WriteFile(path, []byte(content), 0o600); err != nil {
			t.Fatal(err)
		}
		if _, err := Load(path); err == nil {
			t.Errorf("%s: loaded", name)
		}
	}
	path := filepath.Join(dir, "old")
	if _, err := Load(path); !errors.Is(err, ErrFormat) {
		t.Errorf("old format: %v", err)
	}
}
