package store

import (
	"bytes"
	"container/list"
	"crypto/rand"
	"crypto/sha256"
	"encoding/base64"
	"encoding/hex"
	"errors"
	"io"
	"net/url"
	"os"
	"path/filepath"
	"strings"
	"sync"
	"unicode"
	"unicode/utf8"

	"github.com/pmezard/go-difflib/difflib"

	"github.com/guiyuanju/overlook/remote/internal/bridge"
)

// ImageTypes maps the accepted MIME types to file extensions.
var ImageTypes = map[string]string{
	"image/png":  "png",
	"image/jpeg": "jpg",
	"image/gif":  "gif",
	"image/webp": "webp",
}

// extTypes maps image file extensions to MIME types.
var extTypes = map[string]string{
	"png":  "image/png",
	"jpg":  "image/jpeg",
	"jpeg": "image/jpeg",
	"gif":  "image/gif",
	"webp": "image/webp",
}

// Image store bounds.
const (
	DefaultMaxImages     = 500
	DefaultMaxImageBytes = 512 << 20
)

// SniffImage returns the MIME type data's magic bytes announce, or "".
func SniffImage(data []byte) string {
	switch {
	case bytes.HasPrefix(data, []byte("\x89PNG")):
		return "image/png"
	case bytes.HasPrefix(data, []byte("\xff\xd8\xff")):
		return "image/jpeg"
	case bytes.HasPrefix(data, []byte("GIF8")):
		return "image/gif"
	case len(data) >= 12 && bytes.HasPrefix(data, []byte("RIFF")) && string(data[8:12]) == "WEBP":
		return "image/webp"
	}
	return ""
}

// Image is a stored image.
type Image struct {
	ID   string
	MIME string
	Size int64
	Open func() (io.ReadSeekCloser, error)
}

type mediaEntry struct {
	id, mime, path string
	size           int64
}

// media is the content-addressed, LRU-bounded image store.
type media struct {
	dir      string
	maxCount int
	maxBytes int64

	mu    sync.Mutex
	byID  map[string]*list.Element
	lru   *list.List
	total int64
}

func newMedia(dir string, maxCount int, maxBytes int64) *media {
	return &media{dir: dir, maxCount: maxCount, maxBytes: maxBytes, byID: map[string]*list.Element{}, lru: list.New()}
}

// add stores data of type mime and returns its id.
func (m *media) add(data []byte, mime string) (string, error) {
	sum := sha256.Sum256(data)
	id := hex.EncodeToString(sum[:8])
	m.mu.Lock()
	defer m.mu.Unlock()
	if el, ok := m.byID[id]; ok {
		m.lru.MoveToFront(el)
		return id, nil
	}
	dir := filepath.Join(m.dir, "images")
	if err := os.MkdirAll(dir, 0o700); err != nil {
		return "", err
	}
	path := filepath.Join(dir, id)
	if err := os.WriteFile(path, data, 0o600); err != nil {
		return "", err
	}
	m.byID[id] = m.lru.PushFront(&mediaEntry{id: id, mime: mime, path: path, size: int64(len(data))})
	m.total += int64(len(data))
	for m.lru.Len() > 1 && (m.lru.Len() > m.maxCount || m.total > m.maxBytes) {
		old := m.lru.Remove(m.lru.Back()).(*mediaEntry)
		delete(m.byID, old.id)
		m.total -= old.size
		_ = os.Remove(old.path)
	}
	return id, nil
}

func (m *media) get(id string) (mediaEntry, bool) {
	m.mu.Lock()
	defer m.mu.Unlock()
	el, ok := m.byID[id]
	if !ok {
		return mediaEntry{}, false
	}
	m.lru.MoveToFront(el)
	return *el.Value.(*mediaEntry), true
}

// addData stores a base64 image whose bytes must match mime.
func (m *media) addData(b64, mime string) (string, bool) {
	if base64.StdEncoding.DecodedLen(len(b64)) > bridge.MaxImageBytes+3 {
		return "", false
	}
	data, err := base64.StdEncoding.DecodeString(b64)
	if err != nil || len(data) > bridge.MaxImageBytes || SniffImage(data) != mime {
		return "", false
	}
	id, err := m.add(data, mime)
	return id, err == nil
}

// addFile stores a regular image file whose magic bytes match its extension.
func (m *media) addFile(path string) (string, bool) {
	ext := strings.ToLower(strings.TrimPrefix(filepath.Ext(path), "."))
	mime := extTypes[ext]
	if mime == "" {
		return "", false
	}
	fi, err := os.Stat(path)
	if err != nil || !fi.Mode().IsRegular() || fi.Size() > bridge.MaxImageBytes {
		return "", false
	}
	data, err := os.ReadFile(path)
	if err != nil || len(data) > bridge.MaxImageBytes || SniffImage(data) != mime {
		return "", false
	}
	id, err := m.add(data, mime)
	return id, err == nil
}

// Image returns the stored image id.
func (s *Store) Image(id string) (Image, error) {
	e, ok := s.media.get(id)
	if !ok {
		return Image{}, ErrImageMissing
	}
	return Image{ID: e.id, MIME: e.mime, Size: e.size, Open: func() (io.ReadSeekCloser, error) {
		f, err := os.Open(e.path)
		if errors.Is(err, os.ErrNotExist) {
			return nil, ErrImageMissing
		}
		return f, err
	}}, nil
}

// SaveUpload writes an upload as a 0600 file and returns its path and attach name; the caller deletes it.
func (s *Store) SaveUpload(data []byte, mime string) (path, name string, err error) {
	ext, ok := ImageTypes[mime]
	if !ok {
		return "", "", errors.New("store: unsupported upload type")
	}
	dir := filepath.Join(s.opts.Dir, "uploads")
	if err := os.MkdirAll(dir, 0o700); err != nil {
		return "", "", err
	}
	now := s.opts.Now().UTC()
	name = "phone-" + now.Format("20060102-150405") + "-" + now.Format(".000")[1:] + "." + ext
	var nonce [6]byte
	_, _ = rand.Read(nonce[:])
	path = filepath.Join(dir, hex.EncodeToString(nonce[:])+"-"+name)
	if err := os.WriteFile(path, data, 0o600); err != nil {
		return "", "", err
	}
	return path, name, nil
}

// pathByte reports whether b may appear in an unquoted image path.
func pathByte(b byte) bool {
	if b <= ' ' || b >= 0x7f {
		return false
	}
	return !strings.ContainsRune("][\"'`()<>|,;", rune(b))
}

// symbolRune reports whether r continues a name, so an extension before it is not one.
func symbolRune(r rune) bool {
	return r == '_' || r == '-' || unicode.IsLetter(r) || unicode.IsDigit(r)
}

// imageExt returns the length of the image extension (".png" …) s ends with, or 0.
func imageExt(s string) int {
	for ext := range extTypes {
		n := len(ext) + 1
		if len(s) > n && s[len(s)-n] == '.' && strings.EqualFold(s[len(s)-len(ext):], ext) {
			return n
		}
	}
	return 0
}

// ResolvePath percent-decodes p, expands ~/ and resolves it against root; false when p is relative and root empty.
func ResolvePath(p, root string) (string, bool) {
	if dec, err := url.PathUnescape(p); err == nil {
		p = dec
	}
	if rest, ok := strings.CutPrefix(p, "~/"); ok {
		if home, err := os.UserHomeDir(); err == nil {
			p = filepath.Join(home, rest)
		}
	}
	if !filepath.IsAbs(p) {
		if root == "" {
			return "", false
		}
		p = filepath.Join(root, p)
	}
	return filepath.Clean(p), true
}

// ImagePaths returns the image file paths named in text, resolved against root (protocol section 8).
func ImagePaths(text, root string) []string {
	var out []string
	seen := map[string]bool{}
	add := func(p string) {
		p, ok := ResolvePath(p, root)
		if ok && !seen[p] {
			seen[p] = true
			out = append(out, p)
		}
	}
	for i := 0; i < len(text); {
		if strings.HasPrefix(text[i:], `@"`) {
			if end := strings.IndexAny(text[i+2:], "\"\n"); end > 0 && text[i+2+end] == '"' {
				if inner := text[i+2 : i+2+end]; imageExt(inner) > 0 {
					add(inner)
					i += end + 3
					continue
				}
			}
		}
		if !pathByte(text[i]) {
			_, size := utf8.DecodeRuneInString(text[i:])
			i += size
			continue
		}
		j := i
		for j < len(text) && pathByte(text[j]) {
			j++
		}
		start := i
		if strings.HasPrefix(text[i:j], "file://") {
			start += len("file://")
		} else if text[i] == '@' {
			start++
		}
		end := -1
		for k := j; k > start; k-- {
			if imageExt(text[start:k]) == 0 {
				continue
			}
			if k < len(text) {
				if r, _ := utf8.DecodeRuneInString(text[k:]); symbolRune(r) {
					continue
				}
			}
			end = k
			break
		}
		if end < 0 {
			i = j
			continue
		}
		add(text[start:end])
		i = end
	}
	return out
}

// splitLines splits s into lines that each end in a newline.
func splitLines(s string) []string {
	if s == "" {
		return nil
	}
	lines := strings.SplitAfter(s, "\n")
	if lines[len(lines)-1] == "" {
		lines = lines[:len(lines)-1]
	} else {
		lines[len(lines)-1] += "\n"
	}
	return lines
}

// UnifiedDiff renders diffs as one unified diff cut at DiffChars.
func UnifiedDiff(diffs []bridge.Diff) string {
	var b strings.Builder
	for _, d := range diffs {
		file := d.File
		if file == "" {
			file = "file"
		}
		text, err := difflib.GetUnifiedDiffString(difflib.UnifiedDiff{
			A: splitLines(d.Old), B: splitLines(d.New), FromFile: file, ToFile: file, Context: 3,
		})
		if err == nil {
			b.WriteString(text)
		}
	}
	return Cut(b.String(), DiffChars)
}

// Cut shortens s to n characters, marking the cut with "\n…".
func Cut(s string, n int) string {
	if utf8.RuneCountInString(s) <= n {
		return s
	}
	i := 0
	for range n {
		_, size := utf8.DecodeRuneInString(s[i:])
		i += size
	}
	return s[:i] + "\n…"
}
