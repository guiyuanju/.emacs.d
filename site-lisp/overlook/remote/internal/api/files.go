package api

import (
	"context"
	"crypto/rand"
	"encoding/hex"
	"errors"
	"io/fs"
	"mime"
	"net/http"
	"net/url"
	"os"
	"path/filepath"
	"regexp"
	"strings"
	"sync"
	"time"

	"github.com/guiyuanju/overlook/remote/internal/bridge"
	"github.com/guiyuanju/overlook/remote/internal/store"
)

// FileTicketTTL bounds how long a download link works.
const FileTicketTTL = 10 * time.Minute

// filePrefix is the unauthenticated download route; the ticket in it is the credential.
const filePrefix = "/overlook/files/"

// FileLink is the answer to a file request: what the page asks the user to confirm, and where to download it.
type FileLink struct {
	Name string `json:"name"`
	Size int64  `json:"size"`
	URL  string `json:"url"`
}

type fileTicket struct {
	path    string
	expires time.Time
}

// fileTickets maps random download tickets to file paths until they expire.
type fileTickets struct {
	mu      sync.Mutex
	entries map[string]fileTicket
	now     func() time.Time
}

func newFileTickets() *fileTickets {
	return &fileTickets{entries: map[string]fileTicket{}, now: time.Now}
}

func (t *fileTickets) issue(path string) string {
	var b [16]byte
	_, _ = rand.Read(b[:])
	id := hex.EncodeToString(b[:])
	t.mu.Lock()
	defer t.mu.Unlock()
	now := t.now()
	for k, e := range t.entries {
		if !now.Before(e.expires) {
			delete(t.entries, k)
		}
	}
	t.entries[id] = fileTicket{path: path, expires: now.Add(FileTicketTTL)}
	return id
}

func (t *fileTickets) path(id string) (string, bool) {
	t.mu.Lock()
	defer t.mu.Unlock()
	e, ok := t.entries[id]
	if !ok || !t.now().Before(e.expires) {
		return "", false
	}
	return e.path, true
}

// lineSuffix matches a trailing ":12", ":12:3" or ":12-20" that links to a line rather than naming the file.
var lineSuffix = regexp.MustCompile(`:\d+(?:[:-]\d+)?$`)

var errFileMissing = errors.New("file missing")

// fileProblem is the answer for a path that is not offered for download.
func fileProblem() Problem {
	return NewProblem(http.StatusNotFound, CodeFileMissing, "That file is not in this conversation or no longer exists")
}

// mentioned reports whether ref appears in conversation id, falling back to the reply Emacs shows when no activity is retained.
func (s *Server) mentioned(ctx context.Context, id string, needles ...string) (bool, error) {
	found, empty, err := s.d.Store.Mentions(id, needles...)
	if err != nil || found || !empty {
		return found, err
	}
	ctx, cancel := context.WithTimeout(ctx, bridge.Timeout(bridge.MethodEarlier))
	defer cancel()
	res, err := s.d.Emacs.Earlier(ctx, bridge.ConversationParams{Conversation: id})
	if err != nil {
		return false, nil
	}
	for _, n := range needles {
		if n != "" && strings.Contains(res.Reply, n) {
			return true, nil
		}
	}
	return false, nil
}

// regularFile resolves ref against root to an existing regular file, retrying without a line suffix.
func regularFile(ref, root string) (string, fs.FileInfo, error) {
	try := func(ref string) (string, fs.FileInfo, error) {
		p, ok := resolveRef(ref, root)
		if !ok {
			return "", nil, errFileMissing
		}
		fi, err := os.Stat(p)
		if err != nil || !fi.Mode().IsRegular() {
			return "", nil, errFileMissing
		}
		return p, fi, nil
	}
	p, fi, err := try(ref)
	if err != nil && lineSuffix.MatchString(ref) {
		return try(lineSuffix.ReplaceAllString(ref, ""))
	}
	return p, fi, err
}

func resolveRef(ref, root string) (string, bool) {
	if rest, ok := strings.CutPrefix(ref, "file://"); ok {
		ref = strings.TrimPrefix(rest, "localhost")
	}
	return store.ResolvePath(ref, root)
}

// fileLink offers a file named in the conversation for download.
func (s *Server) fileLink(w http.ResponseWriter, r *http.Request) {
	id := r.PathValue("conversation")
	var req struct {
		Path *string `json:"path"`
	}
	p := decode(w, r, &req, true)
	if p == nil && (req.Path == nil || strings.TrimSpace(*req.Path) == "") {
		p = required("path")
	}
	if p != nil {
		WriteProblem(w, *p)
		return
	}
	ref := strings.TrimSpace(*req.Path)
	st, err := s.d.Store.Conversation(id)
	if err != nil {
		WriteProblem(w, storeProblem(err))
		return
	}
	needles := []string{ref}
	if dec, err := url.PathUnescape(ref); err == nil && dec != ref {
		needles = append(needles, dec)
	}
	if ok, err := s.mentioned(r.Context(), id, needles...); err != nil {
		WriteProblem(w, storeProblem(err))
		return
	} else if !ok {
		WriteProblem(w, fileProblem())
		return
	}
	path, fi, err := regularFile(ref, st.Root)
	if err != nil {
		WriteProblem(w, fileProblem())
		return
	}
	name := filepath.Base(path)
	ticket := s.files.issue(path)
	w.Header().Set("Cache-Control", "no-store")
	writeJSON(w, r, http.StatusOK, FileLink{Name: name, Size: fi.Size(), URL: filePrefix + ticket + "/" + url.PathEscape(name)}, "")
}

// fileDownload sends the file a live ticket names as an attachment.
func (s *Server) fileDownload(w http.ResponseWriter, r *http.Request) {
	h := w.Header()
	h.Set("X-Content-Type-Options", "nosniff")
	h.Set("Referrer-Policy", "no-referrer")
	h.Set("Content-Security-Policy", "default-src 'none'; sandbox")
	h.Set("Cache-Control", "no-store")
	path, ok := s.files.path(r.PathValue("ticket"))
	if !ok {
		http.Error(w, "This download link has expired. Tap the file again.", http.StatusNotFound)
		return
	}
	f, err := os.Open(path)
	if err != nil {
		http.Error(w, "That file no longer exists.", http.StatusNotFound)
		return
	}
	defer f.Close()
	fi, err := f.Stat()
	if err != nil || !fi.Mode().IsRegular() {
		http.Error(w, "That file no longer exists.", http.StatusNotFound)
		return
	}
	name := filepath.Base(path)
	h.Set("Content-Type", "application/octet-stream")
	h.Set("Content-Disposition", mime.FormatMediaType("attachment", map[string]string{"filename": name}))
	http.ServeContent(w, r, "", fi.ModTime(), f)
}
