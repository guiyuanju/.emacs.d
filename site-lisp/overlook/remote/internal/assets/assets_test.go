package assets

import (
	"bytes"
	"compress/gzip"
	"crypto/sha256"
	"encoding/base64"
	"encoding/json"
	"io"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"regexp"
	"strings"
	"testing"
	"testing/fstest"
	"time"

	"github.com/andybalholm/brotli"

	"github.com/guiyuanju/overlook/remote/web"
)

var page = fstest.MapFS{
	"index.html": {Data: []byte(`<!doctype html><html><head>
<!-- overlook:importmap -->
<link rel="stylesheet" href="assets/app.css">
<link rel="manifest" href="/overlook/manifest.webmanifest">
<script type="module" src="assets/js/main.js"></script>
</head><body></body></html>`)},
	"js/main.js":         {Data: []byte(`import { api } from "js/api.js";` + strings.Repeat("\n// padding so it compresses", 40))},
	"js/api.js":          {Data: []byte(`export const api = 1;`)},
	"app.css":            {Data: []byte(`body{background:url(img/bg.png)} .x{background:url("data:image/png;base64,AA")}` + strings.Repeat("\n.a{color:red}", 40))},
	"img/bg.png":         {Data: []byte("\x89PNG....")},
	"remote.webmanifest": {Data: []byte(`{"name":"Overlook"}`)},
	"icon-180.png":       {Data: []byte("\x89PNG180")},
	"embed.go":           {Data: []byte("package web")},
	"test/page.test.js":  {Data: []byte("test")},
	".hidden":            {Data: []byte("x")},
}

func get(t *testing.T, a *Assets, path string, header http.Header) *http.Response {
	t.Helper()
	r := httptest.NewRequest("GET", path, nil)
	for k, v := range header {
		r.Header[k] = v
	}
	w := httptest.NewRecorder()
	a.ServeHTTP(w, r)
	return w.Result()
}

func body(t *testing.T, resp *http.Response) string {
	t.Helper()
	var r io.Reader = resp.Body
	switch resp.Header.Get("Content-Encoding") {
	case "br":
		r = brotli.NewReader(resp.Body)
	case "gzip":
		gz, err := gzip.NewReader(resp.Body)
		if err != nil {
			t.Fatal(err)
		}
		r = gz
	}
	data, err := io.ReadAll(r)
	if err != nil {
		t.Fatal(err)
	}
	return string(data)
}

func TestIndexRendering(t *testing.T) {
	a, err := NewLevel(page, 4)
	if err != nil {
		t.Fatal(err)
	}
	resp := get(t, a, "/overlook/", nil)
	html := body(t, resp)
	main, api, css := a.URL("js/main.js"), a.URL("js/api.js"), a.URL("app.css")
	if !regexp.MustCompile(`^/overlook/assets/js/main\.[0-9a-f]{10}\.js$`).MatchString(main) {
		t.Fatalf("hashed url %s", main)
	}
	for _, want := range []string{
		`"js/api.js":"` + api + `"`, `"js/main.js":"` + main + `"`,
		`src="` + main + `"`, `href="` + css + `"`, `href="/overlook/manifest.webmanifest"`,
	} {
		if !strings.Contains(html, want) {
			t.Errorf("index lacks %s:\n%s", want, html)
		}
	}
	if strings.Contains(html, Placeholder) {
		t.Error("placeholder left in index")
	}
	script := regexp.MustCompile(`<script type="importmap">(.*?)</script>`).FindStringSubmatch(html)[1]
	sum := sha256.Sum256([]byte(script))
	csp := resp.Header.Get("Content-Security-Policy")
	if !strings.Contains(csp, "script-src 'self' 'sha256-"+base64.StdEncoding.EncodeToString(sum[:])+"';") ||
		!strings.Contains(csp, "frame-ancestors 'none'") || !strings.Contains(csp, "style-src 'self';") {
		t.Errorf("csp %s", csp)
	}
	h := resp.Header
	if h.Get("Cache-Control") != "no-cache" || h.Get("ETag") == "" || h.Get("X-Content-Type-Options") != "nosniff" ||
		h.Get("Referrer-Policy") != "no-referrer" || !strings.HasPrefix(h.Get("Content-Type"), "text/html") {
		t.Errorf("index headers %v", h)
	}
	if got := get(t, a, "/overlook/", http.Header{"If-None-Match": {h.Get("ETag")}}); got.StatusCode != 304 {
		t.Errorf("revalidation: %d", got.StatusCode)
	}
	cssBody := body(t, get(t, a, css, nil))
	if !strings.Contains(cssBody, "url("+a.URL("img/bg.png")+")") || !strings.Contains(cssBody, `url("data:image/png;base64,AA")`) {
		t.Errorf("css not rewritten: %.120s", cssBody)
	}
}

func TestServing(t *testing.T) {
	a, err := NewLevel(page, 4)
	if err != nil {
		t.Fatal(err)
	}
	main := a.URL("js/main.js")
	tests := []struct {
		name, path, encoding string
		status               int
		cache, ctype, enc    string
	}{
		{"hashed brotli", main, "gzip, br", 200, "public, max-age=31536000, immutable", "text/javascript; charset=utf-8", "br"},
		{"hashed gzip", main, "gzip", 200, "public, max-age=31536000, immutable", "text/javascript; charset=utf-8", "gzip"},
		{"hashed identity", main, "", 200, "public, max-age=31536000, immutable", "text/javascript; charset=utf-8", ""},
		{"unhashed fallback", "/overlook/assets/js/api.js", "", 200, "no-cache", "text/javascript; charset=utf-8", ""},
		{"stable manifest", "/overlook/manifest.webmanifest", "", 200, "no-cache", "application/manifest+json", ""},
		{"stable touch icon", "/overlook/apple-touch-icon.png", "", 200, "no-cache", "image/png", ""},
		{"stable icon missing from web", "/overlook/icon-512.png", "", 404, "", "", ""},
		{"go source", "/overlook/assets/embed.go", "", 404, "", "", ""},
		{"page tests", "/overlook/assets/test/page.test.js", "", 404, "", "", ""},
		{"dot file", "/overlook/assets/.hidden", "", 404, "", "", ""},
		{"wrong hash", "/overlook/assets/js/main.0000000000.js", "", 404, "", "", ""},
	}
	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			h := http.Header{}
			if tt.encoding != "" {
				h.Set("Accept-Encoding", tt.encoding)
			}
			resp := get(t, a, tt.path, h)
			if resp.StatusCode != tt.status {
				t.Fatalf("status %d", resp.StatusCode)
			}
			if tt.status != 200 {
				return
			}
			if resp.Header.Get("Cache-Control") != tt.cache || resp.Header.Get("Content-Type") != tt.ctype || resp.Header.Get("Content-Encoding") != tt.enc {
				t.Fatalf("headers %v", resp.Header)
			}
			if tt.path == main && !strings.HasPrefix(body(t, resp), `import { api }`) {
				t.Fatal("body does not decode")
			}
		})
	}
	r := httptest.NewRequest("POST", "/overlook/", nil)
	w := httptest.NewRecorder()
	a.ServeHTTP(w, r)
	if w.Code != 405 || w.Header().Get("Allow") != "GET, HEAD" {
		t.Fatalf("POST: %d %v", w.Code, w.Header())
	}
}

func TestRealPage(t *testing.T) {
	a, err := NewLevel(web.FS, 4)
	if err != nil {
		t.Fatal(err)
	}
	html := body(t, get(t, a, "/overlook/", nil))
	if strings.Contains(html, Placeholder) || strings.Contains(html, `="assets/`) {
		t.Fatalf("unrendered references in the real index.html:\n%s", html)
	}
	for route := range Stable {
		if resp := get(t, a, route, nil); resp.StatusCode != 200 {
			t.Errorf("%s: %d", route, resp.StatusCode)
		}
	}
	for _, u := range a.cur.Load().urls {
		if resp := get(t, a, u, http.Header{"Accept-Encoding": {"br"}}); resp.StatusCode != 200 {
			t.Errorf("%s: %d", u, resp.StatusCode)
		}
	}
}

func TestNegotiate(t *testing.T) {
	tests := map[string]string{"br": "br", "gzip, deflate, br": "br", "gzip": "gzip", "br;q=0, gzip": "gzip", "identity": "", "": ""}
	for header, want := range tests {
		if got := Negotiate(header); got != want {
			t.Errorf("Negotiate(%q) = %q", header, got)
		}
	}
	if !bytes.Equal([]byte(Placeholder), []byte("<!-- overlook:importmap -->")) {
		t.Fatal("placeholder changed")
	}
}

func writePage(t *testing.T, dir string) {
	t.Helper()
	for name, f := range page {
		p := filepath.Join(dir, name)
		if err := os.MkdirAll(filepath.Dir(p), 0o755); err != nil {
			t.Fatal(err)
		}
		if err := os.WriteFile(p, f.Data, 0o644); err != nil {
			t.Fatal(err)
		}
	}
}

func importMap(t *testing.T, html string) map[string]string {
	t.Helper()
	m := regexp.MustCompile(`<script type="importmap">(.*?)</script>`).FindStringSubmatch(html)
	if m == nil {
		t.Fatalf("no import map in %s", html)
	}
	var v struct{ Imports map[string]string }
	if err := json.Unmarshal([]byte(m[1]), &v); err != nil {
		t.Fatal(err)
	}
	return v.Imports
}

func TestDirReload(t *testing.T) {
	dir := t.TempDir()
	writePage(t, dir)
	a, err := Open(nil, Options{Level: 9, Dir: dir})
	if err != nil {
		t.Fatal(err)
	}
	first := get(t, a, "/overlook/", nil)
	oldAPI := importMap(t, body(t, first))["js/api.js"]

	if err := os.WriteFile(filepath.Join(dir, "js/api.js"), []byte(`export const api = 2;`), 0o644); err != nil {
		t.Fatal(err)
	}
	second := get(t, a, "/overlook/", nil)
	html := body(t, second)
	newAPI := importMap(t, html)["js/api.js"]
	if newAPI == oldAPI || second.Header.Get("ETag") == first.Header.Get("ETag") {
		t.Fatalf("change not picked up: %s", newAPI)
	}
	script := regexp.MustCompile(`<script type="importmap">(.*?)</script>`).FindStringSubmatch(html)[1]
	sum := sha256.Sum256([]byte(script))
	if !strings.Contains(second.Header.Get("Content-Security-Policy"), base64.StdEncoding.EncodeToString(sum[:])) {
		t.Errorf("csp not recomputed: %s", second.Header.Get("Content-Security-Policy"))
	}
	if got := body(t, get(t, a, newAPI, nil)); got != `export const api = 2;` {
		t.Errorf("new module %q", got)
	}
	if got := body(t, get(t, a, oldAPI, nil)); got != `export const api = 1;` {
		t.Errorf("a page loaded before the change lost its module: %q", got)
	}

	// A big new file is served at once with fast variants, then at full quality.
	big := strings.Repeat("export const filler = 'the quick brown fox jumps over the lazy dog';\n", 400)
	if err := os.WriteFile(filepath.Join(dir, "js/big.js"), []byte(big), 0o644); err != nil {
		t.Fatal(err)
	}
	u := importMap(t, body(t, get(t, a, "/overlook/", nil)))["js/big.js"]
	if got := body(t, get(t, a, u, http.Header{"Accept-Encoding": {"br"}})); got != big {
		t.Fatal("fast variant does not decode")
	}
	a.cache.bg.Wait()
	get(t, a, "/overlook/", nil)
	var full bytes.Buffer
	bw := brotli.NewWriterLevel(&full, 9)
	_, _ = bw.Write([]byte(big))
	_ = bw.Close()
	if f := a.cur.Load().files["js/big.js"]; !bytes.Equal(f.br, full.Bytes()) {
		t.Errorf("full-quality variant not swapped in: %d bytes, want %d", len(f.br), full.Len())
	}

	// A broken page keeps the last good build.
	if err := os.Remove(filepath.Join(dir, "index.html")); err != nil {
		t.Fatal(err)
	}
	if resp := get(t, a, "/overlook/", nil); resp.StatusCode != 200 || !strings.Contains(body(t, resp), "importmap") {
		t.Fatalf("lost the page: %d", resp.StatusCode)
	}
}

func TestCacheDir(t *testing.T) {
	cacheDir := t.TempDir()
	a, err := Open(page, Options{Level: 4, CacheDir: cacheDir})
	if err != nil {
		t.Fatal(err)
	}
	f := a.cur.Load().files["js/main.js"]
	brFile := filepath.Join(cacheDir, a.cache.brName(f.sum))
	if _, err := os.Stat(brFile); err != nil {
		t.Fatalf("variant not cached: %v", err)
	}
	// A second start reads the variants instead of compressing; a marker proves it.
	var marker bytes.Buffer
	bw := brotli.NewWriterLevel(&marker, 1)
	_, _ = bw.Write([]byte("from the cache"))
	_ = bw.Close()
	if err := os.WriteFile(brFile, marker.Bytes(), 0o600); err != nil {
		t.Fatal(err)
	}
	b, err := Open(page, Options{Level: 4, CacheDir: cacheDir})
	if err != nil {
		t.Fatal(err)
	}
	if got := body(t, get(t, b, b.URL("js/main.js"), http.Header{"Accept-Encoding": {"br"}})); got != "from the cache" {
		t.Fatalf("second start compressed again: %.40q", got)
	}

	stale := filepath.Join(cacheDir, "0000-q4.br")
	if err := os.WriteFile(stale, []byte("x"), 0o600); err != nil {
		t.Fatal(err)
	}
	old := time.Now().Add(-2 * pruneAge)
	if err := os.Chtimes(stale, old, old); err != nil {
		t.Fatal(err)
	}
	if err := os.Chtimes(brFile, old, old); err != nil {
		t.Fatal(err)
	}
	b.cache.prune(b.cur.Load())
	if _, err := os.Stat(stale); !os.IsNotExist(err) {
		t.Error("unused old cache file kept")
	}
	if _, err := os.Stat(brFile); err != nil {
		t.Error("used cache file pruned")
	}
}
