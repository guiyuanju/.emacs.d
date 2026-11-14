package main

import (
	"os"
	"path/filepath"
	"regexp"
	"strings"
	"testing"
	"time"
)

// TestWebDirReload serves the page from disk: an edited module shows up on the next page load, no restart.
func TestWebDirReload(t *testing.T) {
	cfg := baseConfig(t)
	cfg.FakeEmacs = ""
	cfg.WebDir = t.TempDir()
	if err := os.CopyFS(cfg.WebDir, os.DirFS("../../web")); err != nil {
		t.Fatal(err)
	}
	cfg.CacheDir = t.TempDir()
	r := launch(t, cfg)
	apiURL := regexp.MustCompile(`"js/api.js":"([^"]+)"`)
	first := apiURL.FindStringSubmatch(string(r.get("/overlook/").body))
	if first == nil {
		t.Fatal("no import map entry for js/api.js")
	}
	file := filepath.Join(cfg.WebDir, "js", "api.js")
	data, err := os.ReadFile(file)
	if err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(file, append(data, []byte("\n// edited\n")...), 0o644); err != nil {
		t.Fatal(err)
	}
	started := time.Now()
	second := apiURL.FindStringSubmatch(string(r.get("/overlook/").body))
	t.Logf("page rebuilt in %v", time.Since(started))
	if second == nil || second[1] == first[1] {
		t.Fatalf("edit not picked up: %v", second)
	}
	if res := r.get(second[1]); res.status != 200 || !strings.HasSuffix(string(res.body), "// edited\n") {
		t.Fatalf("edited module: %d", res.status)
	}
	if res := r.get(first[1]); res.status != 200 {
		t.Fatalf("the module of a page loaded before the edit: %d", res.status)
	}
}
