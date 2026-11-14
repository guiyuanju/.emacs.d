// Package assets serves the embedded page with hashed URLs, precompression and strict headers.
//
// Conventions shared with the page (docs/contract-changes.md): index.html holds the line
// `<!-- overlook:importmap -->`, replaced by an import map from each served *.js path
// (relative to web/) to its hashed URL; src/href values starting with "assets/" are
// rewritten to hashed URLs.
package assets

import (
	"bytes"
	"crypto/sha256"
	"encoding/base64"
	"encoding/hex"
	"encoding/json"
	"fmt"
	"io"
	"io/fs"
	"log/slog"
	"mime"
	"net/http"
	"os"
	"path"
	"regexp"
	"sort"
	"strconv"
	"strings"
	"sync"
	"sync/atomic"

	"github.com/andybalholm/brotli"
)

// Prefix is where hashed and unhashed page files are served.
const Prefix = "/overlook/assets/"

// Placeholder is the line of index.html the import map replaces.
const Placeholder = "<!-- overlook:importmap -->"

// Stable routes the Home Screen link and manifest depend on, mapped to web files.
var Stable = map[string]string{
	"/overlook/manifest.webmanifest": "remote.webmanifest",
	"/overlook/icon.svg":             "icon.svg",
	"/overlook/apple-touch-icon.png": "icon-180.png",
	"/overlook/icon-192.png":         "icon-192.png",
	"/overlook/icon-512.png":         "icon-512.png",
}

// cspFormat is the page's policy; %s is the list of inline script hashes.
const cspFormat = "default-src 'self'; script-src 'self'%s; style-src 'self'; img-src 'self' blob: data:; " +
	"font-src 'self' data:; connect-src 'self'; manifest-src 'self'; object-src 'none'; " +
	"base-uri 'none'; form-action 'none'; frame-ancestors 'none'"

// file is one servable file with its compressed variants.
type file struct {
	name  string
	ctype string
	sum   string // sha256 of raw, hex; the compression cache key
	etag  string
	raw   []byte
	br    []byte
	gz    []byte
}

// set is one immutable build of the page.
type set struct {
	files  map[string]*file // by web path
	hashed map[string]*file // by hashed URL
	urls   map[string]string
	index  *file
	csp    string
}

// Options configures Open.
type Options struct {
	// Level is the brotli quality of the precompressed variants; zero means the best.
	Level int
	// CacheDir keeps compressed variants by content hash across restarts; empty keeps them in memory only.
	CacheDir string
	// Dir serves the page from this directory instead of fsys, rebuilding when its files change.
	Dir string
	// Log receives reload and cache problems; nil discards them.
	Log *slog.Logger
}

// Assets serves index.html at /overlook/ and every other page file at /overlook/assets/<name>.<hash>.<ext>.
type Assets struct {
	opts  Options
	fsys  fs.FS
	cur   atomic.Pointer[set]
	cache *cache

	// mu serializes rebuilds; prev keeps the last builds' hashed URLs for pages loaded just before a change.
	mu    sync.Mutex
	prev  []*set
	stamp string
}

// generations is how many earlier builds keep serving their hashed URLs in Dir mode.
const generations = 3

var (
	cssURL      = regexp.MustCompile(`url\(\s*(['"]?)([^'")]+)(['"]?)\s*\)`)
	attrRef     = regexp.MustCompile(`\b(src|href)="assets/([^"]+)"`)
	inlineBlock = regexp.MustCompile(`(?is)<script\b([^>]*)>(.*?)</script>`)
	srcAttr     = regexp.MustCompile(`(?i)\bsrc\s*=`)
)

// New hashes and precompresses (brotli, gzip) the page files of fsys once.
func New(fsys fs.FS) (*Assets, error) {
	return Open(fsys, Options{})
}

// NewLevel is New with a brotli quality; lower ones start faster.
func NewLevel(fsys fs.FS, brotliLevel int) (*Assets, error) {
	return Open(fsys, Options{Level: brotliLevel})
}

// Open builds the page from fsys, or from opts.Dir when set.
func Open(fsys fs.FS, opts Options) (*Assets, error) {
	if opts.Level == 0 {
		opts.Level = brotli.BestCompression
	}
	if opts.Log == nil {
		opts.Log = slog.New(slog.NewTextHandler(io.Discard, nil))
	}
	a := &Assets{opts: opts, fsys: fsys, cache: newCache(opts.CacheDir, opts.Level, opts.Log)}
	if opts.Dir != "" {
		a.fsys = os.DirFS(opts.Dir)
		a.stamp = fingerprint(a.fsys)
	}
	s, err := a.build()
	if err != nil {
		return nil, err
	}
	a.cur.Store(s)
	go a.cache.prune(s)
	return a, nil
}

// build reads, hashes, renders and compresses the page files of a.fsys.
func (a *Assets) build() (*set, error) {
	s := &set{files: map[string]*file{}, hashed: map[string]*file{}, urls: map[string]string{}}
	contents := map[string][]byte{}
	err := fs.WalkDir(a.fsys, ".", func(name string, d fs.DirEntry, err error) error {
		if err != nil {
			return err
		}
		if name == "." {
			return nil
		}
		if !Served(name) {
			if d.IsDir() {
				return fs.SkipDir
			}
			return nil
		}
		if d.IsDir() {
			return nil
		}
		data, err := fs.ReadFile(a.fsys, name)
		if err != nil {
			return err
		}
		contents[name] = data
		return nil
	})
	if err != nil {
		return nil, err
	}
	names := make([]string, 0, len(contents))
	for name := range contents {
		names = append(names, name)
	}
	sort.Strings(names)
	// CSS references other files, so everything else is hashed first.
	for pass := range 2 {
		for _, name := range names {
			if name == "index.html" || (path.Ext(name) == ".css") != (pass == 1) {
				continue
			}
			data := contents[name]
			if pass == 1 {
				data = s.rewriteCSS(name, data)
			}
			f := s.add(name, data)
			s.urls[name] = hashedURL(name, f.etag)
			s.hashed[s.urls[name]] = f
		}
	}
	html, ok := contents["index.html"]
	if !ok {
		return nil, fmt.Errorf("assets: index.html missing")
	}
	html, hashes, err := s.render(html)
	if err != nil {
		return nil, err
	}
	s.index = s.add("index.html", html)
	s.csp = fmt.Sprintf(cspFormat, hashes)
	a.cache.fill(s, a.opts.Dir != "")
	return s, nil
}

// fingerprint summarizes the names, sizes and modification times of fsys's page files.
func fingerprint(fsys fs.FS) string {
	h := sha256.New()
	_ = fs.WalkDir(fsys, ".", func(name string, d fs.DirEntry, err error) error {
		if err != nil || name == "." {
			return nil
		}
		if !Served(name) {
			if d.IsDir() {
				return fs.SkipDir
			}
			return nil
		}
		if info, err := d.Info(); err == nil && !d.IsDir() {
			fmt.Fprintf(h, "%s\x00%d\x00%d\x00", name, info.Size(), info.ModTime().UnixNano())
		}
		return nil
	})
	return hex.EncodeToString(h.Sum(nil))
}

// refresh rebuilds the page in Dir mode when its files changed or better variants arrived.
func (a *Assets) refresh() *set {
	if a.opts.Dir == "" {
		return a.cur.Load()
	}
	a.mu.Lock()
	defer a.mu.Unlock()
	stamp := fingerprint(a.fsys)
	upgraded := a.cache.upgraded.Swap(false)
	if stamp == a.stamp && !upgraded {
		return a.cur.Load()
	}
	s, err := a.build()
	if err != nil {
		a.opts.Log.Warn("page reload failed; serving the previous build", "dir", a.opts.Dir, "err", err)
		a.stamp = stamp
		return a.cur.Load()
	}
	old := a.cur.Load()
	if stamp != a.stamp {
		a.opts.Log.Info("page reloaded", "dir", a.opts.Dir)
		a.prev = append([]*set{old}, a.prev...)
		if len(a.prev) > generations {
			a.prev = a.prev[:generations]
		}
	}
	a.stamp = stamp
	a.cur.Store(s)
	a.cache.retain(append([]*set{s}, a.prev...))
	return s
}

// lookupHashed finds a hashed URL in the current build or, in Dir mode, a recent one.
func (a *Assets) lookupHashed(s *set, p string) *file {
	if f := s.hashed[p]; f != nil {
		return f
	}
	if a.opts.Dir == "" {
		return nil
	}
	if s = a.refresh(); s.hashed[p] != nil {
		return s.hashed[p]
	}
	a.mu.Lock()
	defer a.mu.Unlock()
	for _, old := range a.prev {
		if f := old.hashed[p]; f != nil {
			return f
		}
	}
	return nil
}

func digest(data []byte) (sum, etag string) {
	full := sha256.Sum256(data)
	sum = hex.EncodeToString(full[:])
	return sum, sum[:10]
}

func hashedURL(name, hash string) string {
	dir, base := path.Split(name)
	ext := path.Ext(base)
	return Prefix + dir + strings.TrimSuffix(base, ext) + "." + hash + ext
}

func (s *set) add(name string, data []byte) *file {
	f := &file{name: name, ctype: contentType(name), raw: data}
	f.sum, f.etag = digest(data)
	s.files[name] = f
	return f
}

// rewriteCSS points relative url() references of CSS file name at hashed URLs.
func (s *set) rewriteCSS(name string, data []byte) []byte {
	return cssURL.ReplaceAllFunc(data, func(m []byte) []byte {
		sub := cssURL.FindSubmatch(m)
		ref := string(sub[2])
		if strings.Contains(ref, ":") || strings.HasPrefix(ref, "/") || strings.HasPrefix(ref, "#") {
			return m
		}
		target, frag, _ := strings.Cut(ref, "#")
		target, _, _ = strings.Cut(target, "?")
		u, ok := s.urls[path.Clean(path.Join(path.Dir(name), target))]
		if !ok {
			return m
		}
		if frag != "" {
			u += "#" + frag
		}
		return []byte("url(" + string(sub[1]) + u + string(sub[3]) + ")")
	})
}

// render fills the import map and hashed references into index.html and returns its inline script hashes.
func (s *set) render(html []byte) ([]byte, string, error) {
	imports := map[string]string{}
	for name, u := range s.urls {
		if ext := path.Ext(name); ext == ".js" || ext == ".mjs" {
			imports[name] = u
		}
	}
	mapJSON, err := json.Marshal(struct {
		Imports map[string]string `json:"imports"`
	}{imports})
	if err != nil {
		return nil, "", err
	}
	script := []byte(`<script type="importmap">` + string(mapJSON) + `</script>`)
	if bytes.Contains(html, []byte(Placeholder)) {
		html = bytes.Replace(html, []byte(Placeholder), script, 1)
	} else if i := bytes.Index(bytes.ToLower(html), []byte("<head>")); i >= 0 {
		html = append(html[:i+6:i+6], append(append([]byte("\n"), script...), html[i+6:]...)...)
	} else {
		html = append(script, html...)
	}
	html = attrRef.ReplaceAllFunc(html, func(m []byte) []byte {
		sub := attrRef.FindSubmatch(m)
		if u, ok := s.urls[string(sub[2])]; ok {
			return []byte(string(sub[1]) + `="` + u + `"`)
		}
		return m
	})
	var hashes strings.Builder
	for _, m := range inlineBlock.FindAllSubmatch(html, -1) {
		if srcAttr.Match(m[1]) || len(m[2]) == 0 {
			continue
		}
		sum := sha256.Sum256(m[2])
		hashes.WriteString(" 'sha256-" + base64.StdEncoding.EncodeToString(sum[:]) + "'")
	}
	return html, hashes.String(), nil
}

// URL returns the hashed URL of page file name.
func (a *Assets) URL(name string) string {
	if u, ok := a.refresh().urls[name]; ok {
		return u
	}
	return Prefix + name
}

// CSP is the Content-Security-Policy of the page.
func (a *Assets) CSP() string { return a.refresh().csp }

// ServeHTTP serves index.html (no-cache, ETag), hashed assets (immutable) and Stable routes.
func (a *Assets) ServeHTTP(w http.ResponseWriter, r *http.Request) {
	h := w.Header()
	h.Set("Content-Security-Policy", a.cur.Load().csp)
	h.Set("X-Content-Type-Options", "nosniff")
	h.Set("Referrer-Policy", "no-referrer")
	h.Set("X-Frame-Options", "DENY")
	if r.Method != http.MethodGet && r.Method != http.MethodHead {
		h.Set("Allow", "GET, HEAD")
		http.Error(w, "method not allowed", http.StatusMethodNotAllowed)
		return
	}
	s := a.cur.Load()
	p := r.URL.Path
	if strings.HasPrefix(p, Prefix) {
		if f := a.lookupHashed(s, p); f != nil {
			serve(w, r, f, true)
			return
		}
	}
	// Everything else is revalidated by the browser, so it is where a changed page shows up.
	s = a.refresh()
	h.Set("Content-Security-Policy", s.csp)
	name := strings.TrimPrefix(p, Prefix)
	switch {
	case p == "/overlook/" || p == "/overlook/index.html":
		serve(w, r, s.index, false)
	case Stable[p] != "" && s.files[Stable[p]] != nil:
		serve(w, r, s.files[Stable[p]], false)
	case strings.HasPrefix(p, Prefix) && s.files[name] != nil && name != "index.html":
		serve(w, r, s.files[name], false)
	default:
		http.NotFound(w, r)
	}
}

func serve(w http.ResponseWriter, r *http.Request, f *file, immutable bool) {
	h := w.Header()
	if immutable {
		h.Set("Cache-Control", "public, max-age=31536000, immutable")
	} else {
		h.Set("Cache-Control", "no-cache")
	}
	h.Set("ETag", `"`+f.etag+`"`)
	h.Set("Content-Type", f.ctype)
	if f.br != nil || f.gz != nil {
		h.Add("Vary", "Accept-Encoding")
	}
	if inm := r.Header.Get("If-None-Match"); inm != "" {
		for _, part := range strings.Split(inm, ",") {
			part = strings.TrimPrefix(strings.TrimSpace(part), "W/")
			if part == `"`+f.etag+`"` || part == "*" {
				w.WriteHeader(http.StatusNotModified)
				return
			}
		}
	}
	body := f.raw
	switch enc := Negotiate(r.Header.Get("Accept-Encoding")); {
	case enc == "br" && f.br != nil:
		body = f.br
		h.Set("Content-Encoding", "br")
	case (enc == "br" || enc == "gzip") && f.gz != nil && acceptsName(r.Header.Get("Accept-Encoding"), "gzip"):
		body = f.gz
		h.Set("Content-Encoding", "gzip")
	}
	h.Set("Content-Length", strconv.Itoa(len(body)))
	w.WriteHeader(http.StatusOK)
	if r.Method != http.MethodHead {
		_, _ = w.Write(body)
	}
}

// Negotiate picks "br", "gzip" or "" from an Accept-Encoding header, preferring brotli.
func Negotiate(header string) string {
	switch {
	case acceptsName(header, "br"):
		return "br"
	case acceptsName(header, "gzip"):
		return "gzip"
	}
	return ""
}

func acceptsName(header, name string) bool {
	for _, part := range strings.Split(header, ",") {
		coding, params, _ := strings.Cut(strings.TrimSpace(part), ";")
		if !strings.EqualFold(strings.TrimSpace(coding), name) {
			continue
		}
		q := strings.TrimSpace(params)
		if v, ok := strings.CutPrefix(strings.ReplaceAll(q, " ", ""), "q="); ok {
			f, err := strconv.ParseFloat(v, 64)
			return err != nil || f > 0
		}
		return true
	}
	return false
}

var types = map[string]string{
	".js":          "text/javascript; charset=utf-8",
	".mjs":         "text/javascript; charset=utf-8",
	".css":         "text/css; charset=utf-8",
	".html":        "text/html; charset=utf-8",
	".json":        "application/json",
	".webmanifest": "application/manifest+json",
	".svg":         "image/svg+xml",
	".png":         "image/png",
	".woff2":       "font/woff2",
	".woff":        "font/woff",
	".map":         "application/json",
	".txt":         "text/plain; charset=utf-8",
}

func contentType(name string) string {
	ext := strings.ToLower(path.Ext(name))
	if t, ok := types[ext]; ok {
		return t
	}
	if t := mime.TypeByExtension(ext); t != "" {
		return t
	}
	if ext == "" || strings.HasSuffix(name, "LICENSE") {
		return "text/plain; charset=utf-8"
	}
	return "application/octet-stream"
}

func compressible(ctype string) bool {
	return strings.HasPrefix(ctype, "text/") || strings.Contains(ctype, "json") ||
		strings.Contains(ctype, "javascript") || strings.Contains(ctype, "svg")
}

// Served reports whether an embedded file is part of the page rather than Go source or tests.
func Served(name string) bool {
	if strings.HasSuffix(name, ".go") || name == "test" || strings.HasPrefix(name, "test/") {
		return false
	}
	for _, part := range strings.Split(name, "/") {
		if strings.HasPrefix(part, ".") || part == "node_modules" {
			return false
		}
	}
	return path.Clean(name) == name
}
