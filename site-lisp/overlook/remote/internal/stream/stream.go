// Package stream serves the page's server-sent event stream.
//
// Streams hold no event queues: a change only marks a stream dirty, and the
// stream reads the store's current state when it flushes, so a slow client
// costs constant memory and simply receives fewer, larger deltas; a client
// that cannot take a write within WriteTimeout is disconnected and resumes
// from its last event id.
package stream

import (
	"bytes"
	"compress/gzip"
	"context"
	"encoding/json"
	"errors"
	"io"
	"net/http"
	"net/url"
	"slices"
	"strconv"
	"strings"
	"sync"
	"time"

	"github.com/guiyuanju/overlook/remote/internal/store"
)

// Event names written in the stream's event: field.
const (
	EventHello        = "hello"
	EventStatus       = "status"
	EventDashboard    = "dashboard"
	EventConversation = "conversation"
	EventGone         = "gone"
)

// Protocol is the browser API protocol announced in hello.
const Protocol = 3

// Source is the state a stream reads; *store.Store implements it.
type Source interface {
	Emacs() store.EmacsStatus
	Epoch() string
	DashboardDelta(known string) (store.DashboardDelta, bool)
	Snapshot(id string) (store.ConversationSnapshot, error)
	Delta(id, epoch string, after int64, known string) (store.ConversationDelta, bool, bool, error)
}

// EarlierFunc fills a reset snapshot's earlier field when it has no items.
type EarlierFunc func(ctx context.Context, snap *store.ConversationSnapshot)

// Options configures a Hub.
type Options struct {
	Coalesce     time.Duration
	Heartbeat    time.Duration
	WriteTimeout time.Duration
	Compress     bool
	MaxStreams   int
	Earlier      EarlierFunc
}

// DefaultOptions are the production values.
var DefaultOptions = Options{
	Coalesce:     200 * time.Millisecond,
	Heartbeat:    25 * time.Second,
	WriteTimeout: 10 * time.Second,
	Compress:     true,
	MaxStreams:   32,
}

// ErrTooManyStreams is returned when MaxStreams streams are open.
var ErrTooManyStreams = errors.New("stream: too many streams")

// ErrClosed is returned when the hub is shutting down.
var ErrClosed = errors.New("stream: hub closed")

// Hub fans changes out to open streams.
type Hub struct {
	src     Source
	opts    Options
	mu      sync.Mutex
	clients map[*client]struct{}
	closed  chan struct{}
	once    sync.Once
}

type client struct {
	sub  Subscription
	wake chan struct{}

	mu     sync.Mutex
	dash   bool
	conv   bool
	status bool
}

// NewHub returns a hub reading from src.
func NewHub(src Source, opts Options) *Hub {
	def := DefaultOptions
	if opts.Coalesce <= 0 {
		opts.Coalesce = def.Coalesce
	}
	if opts.Heartbeat <= 0 {
		opts.Heartbeat = def.Heartbeat
	}
	if opts.WriteTimeout <= 0 {
		opts.WriteTimeout = def.WriteTimeout
	}
	if opts.MaxStreams <= 0 {
		opts.MaxStreams = def.MaxStreams
	}
	return &Hub{src: src, opts: opts, clients: map[*client]struct{}{}, closed: make(chan struct{})}
}

// Close ends every stream; Serve refuses new ones.
func (h *Hub) Close() {
	h.once.Do(func() { close(h.closed) })
}

// Count is the number of open streams.
func (h *Hub) Count() int {
	h.mu.Lock()
	defer h.mu.Unlock()
	return len(h.clients)
}

// Notify marks the streams interested in c dirty; they write within Options.Coalesce.
func (h *Hub) Notify(c store.Change) {
	h.mu.Lock()
	defer h.mu.Unlock()
	for cl := range h.clients {
		cl.mu.Lock()
		hit := false
		if c.Status || c.Epoch {
			cl.status, hit = true, true
		}
		if c.Dashboard && cl.sub.Dashboard {
			cl.dash, hit = true, true
		}
		if id := cl.sub.Conversation; id != "" && (slices.Contains(c.Conversations, id) || slices.Contains(c.Gone, id) || c.Epoch) {
			cl.conv, hit = true, true
		}
		cl.mu.Unlock()
		if hit {
			select {
			case cl.wake <- struct{}{}:
			default:
			}
		}
	}
}

// AcceptsGzip reports whether r's Accept-Encoding allows gzip.
func AcceptsGzip(r *http.Request) bool {
	for _, part := range strings.Split(r.Header.Get("Accept-Encoding"), ",") {
		name, params, _ := strings.Cut(strings.TrimSpace(part), ";")
		if strings.EqualFold(strings.TrimSpace(name), "gzip") || strings.TrimSpace(name) == "*" {
			q := strings.ReplaceAll(strings.TrimSpace(params), " ", "")
			return q != "q=0" && q != "q=0.0" && q != "q=0.00" && q != "q=0.000"
		}
	}
	return false
}

// writer writes SSE frames with per-frame deadlines and flushes.
type writer struct {
	rc      *http.ResponseController
	out     io.Writer
	gz      *gzip.Writer
	timeout time.Duration
	buf     bytes.Buffer
}

func (w *writer) frame(id, event string, data any) error {
	w.buf.Reset()
	if id != "" {
		w.buf.WriteString("id: ")
		w.buf.WriteString(id)
		w.buf.WriteByte('\n')
	}
	w.buf.WriteString("event: ")
	w.buf.WriteString(event)
	w.buf.WriteString("\ndata: ")
	enc := json.NewEncoder(&w.buf)
	enc.SetEscapeHTML(false)
	if err := enc.Encode(data); err != nil {
		return err
	}
	w.buf.WriteByte('\n')
	return w.send(w.buf.Bytes())
}

func (w *writer) send(p []byte) error {
	_ = w.rc.SetWriteDeadline(time.Now().Add(w.timeout))
	if _, err := w.out.Write(p); err != nil {
		return err
	}
	if w.gz != nil {
		if err := w.gz.Flush(); err != nil {
			return err
		}
	}
	return w.rc.Flush()
}

// Serve writes the stream for sub until the client leaves or ctx ends.
// It returns ErrTooManyStreams before writing anything when full.
func (h *Hub) Serve(ctx context.Context, w http.ResponseWriter, r *http.Request, sub Subscription) error {
	cl := &client{sub: sub, wake: make(chan struct{}, 1)}
	h.mu.Lock()
	select {
	case <-h.closed:
		h.mu.Unlock()
		return ErrClosed
	default:
	}
	if len(h.clients) >= h.opts.MaxStreams {
		h.mu.Unlock()
		return ErrTooManyStreams
	}
	h.clients[cl] = struct{}{}
	h.mu.Unlock()
	defer func() {
		h.mu.Lock()
		delete(h.clients, cl)
		h.mu.Unlock()
	}()

	hdr := w.Header()
	hdr.Set("Content-Type", "text/event-stream; charset=utf-8")
	hdr.Set("Cache-Control", "no-store, no-transform")
	hdr.Set("X-Accel-Buffering", "no")
	hdr.Add("Vary", "Accept-Encoding")
	sw := &writer{rc: http.NewResponseController(w), out: w, timeout: h.opts.WriteTimeout}
	if h.opts.Compress && AcceptsGzip(r) {
		hdr.Set("Content-Encoding", "gzip")
		sw.gz, _ = gzip.NewWriterLevel(w, gzip.DefaultCompression)
		sw.out = sw.gz
		defer sw.gz.Close()
	}
	w.WriteHeader(http.StatusOK)

	st := &streamState{h: h, cl: cl, w: sw, emacs: h.src.Emacs(), epoch: h.src.Epoch()}
	if err := sw.frame("", EventHello, store.StreamHello{Protocol: Protocol, Epoch: st.epoch, Emacs: st.emacs}); err != nil {
		return nil
	}
	cl.mu.Lock()
	cl.dash, cl.conv = sub.Dashboard, sub.Conversation != ""
	cl.mu.Unlock()
	if done, err := st.flush(ctx); done || err != nil {
		return nil
	}

	heartbeat := time.NewTimer(h.opts.Heartbeat)
	defer heartbeat.Stop()
	var coalesce <-chan time.Time
	for {
		select {
		case <-ctx.Done():
			return nil
		case <-h.closed:
			return nil
		case <-cl.wake:
			if coalesce == nil {
				coalesce = time.After(h.opts.Coalesce)
			}
			continue
		case <-coalesce:
			coalesce = nil
			wrote := st.wrote
			done, err := st.flush(ctx)
			if done || err != nil {
				return nil
			}
			if st.wrote == wrote {
				continue
			}
		case <-heartbeat.C:
			if err := sw.send([]byte(":\n\n")); err != nil {
				return nil
			}
		}
		heartbeat.Reset(h.opts.Heartbeat)
	}
}

type streamState struct {
	h     *Hub
	cl    *client
	w     *writer
	emacs store.EmacsStatus
	epoch string
	wrote int
}

func (s *streamState) frame(id, event string, data any) error {
	s.wrote++
	return s.w.frame(id, event, data)
}

// flush writes whatever the dirty flags call for; done means the stream should end.
func (s *streamState) flush(ctx context.Context) (done bool, err error) {
	cl := s.cl
	cl.mu.Lock()
	dash, conv, status := cl.dash, cl.conv, cl.status
	cl.dash, cl.conv, cl.status = false, false, false
	sub := cl.sub
	cl.mu.Unlock()
	src := s.h.src

	if status {
		em, ep := src.Emacs(), src.Epoch()
		if em != s.emacs || ep != s.epoch {
			ev := store.StreamStatus{Emacs: em}
			if ep != s.epoch {
				ev.Epoch = ep
			}
			s.emacs, s.epoch = em, ep
			if err := s.frame("", EventStatus, ev); err != nil {
				return true, err
			}
		}
	}
	if dash && sub.Dashboard {
		if d, ok := src.DashboardDelta(sub.DashboardKnown); ok {
			sub.DashboardKnown = d.Known
			s.setSub(sub)
			if err := s.frame(sub.ID(), EventDashboard, d); err != nil {
				return true, err
			}
		}
	}
	if conv && sub.Conversation != "" {
		d, reset, ok, err := src.Delta(sub.Conversation, sub.Epoch, sub.After, sub.Known)
		switch {
		case errors.Is(err, store.ErrConversationMissing):
			gone := sub.Conversation
			sub.Conversation, sub.After, sub.Known, sub.Epoch = "", 0, "", ""
			s.setSub(sub)
			if err := s.frame("", EventGone, store.StreamGone{Conversation: gone}); err != nil {
				return true, err
			}
			return !sub.Dashboard, nil
		case err != nil:
			return false, nil
		case reset:
			snap, err := src.Snapshot(sub.Conversation)
			if err != nil {
				cl.mu.Lock()
				cl.conv = true
				cl.mu.Unlock()
				return false, nil
			}
			if len(snap.Items) == 0 && s.h.opts.Earlier != nil {
				s.h.opts.Earlier(ctx, &snap)
			}
			snap.Reset = true
			sub.Epoch, sub.After, sub.Known = snap.Epoch, snap.Seq, snap.Known
			s.setSub(sub)
			if err := s.frame(sub.ID(), EventConversation, snap); err != nil {
				return true, err
			}
		case ok:
			sub.Epoch, sub.After, sub.Known = d.Epoch, d.Seq, d.Known
			s.setSub(sub)
			if err := s.frame(sub.ID(), EventConversation, d); err != nil {
				return true, err
			}
		}
	}
	return false, nil
}

func (s *streamState) setSub(sub Subscription) {
	s.cl.mu.Lock()
	s.cl.sub = sub
	s.cl.mu.Unlock()
}

// Subscription is what one stream follows and the cursors the client holds.
type Subscription struct {
	Dashboard      bool
	DashboardKnown string
	Conversation   string
	After          int64
	Known          string
	Epoch          string
}

// ParseSubscription reads the query, letting a Last-Event-ID resume query override it.
func ParseSubscription(q url.Values, lastEventID string) (Subscription, error) {
	if lastEventID != "" {
		resumed, err := url.ParseQuery(lastEventID)
		if err != nil {
			return Subscription{}, errors.New("stream: invalid Last-Event-ID")
		}
		q = resumed
	}
	sub := Subscription{
		Conversation: q.Get("conversation"),
		Known:        q.Get("known"),
		Epoch:        q.Get("epoch"),
	}
	_, sub.Dashboard = q["dashboard"]
	sub.DashboardKnown = q.Get("dashboard")
	if v := q.Get("after"); v != "" {
		n, err := strconv.ParseInt(v, 10, 64)
		if err != nil || n < 0 {
			return Subscription{}, errors.New("stream: invalid after")
		}
		sub.After = n
	}
	if !sub.Dashboard && sub.Conversation == "" {
		return Subscription{}, errors.New("stream: subscribe to dashboard or a conversation")
	}
	return sub, nil
}

// ID is the resume query written in each event's id: field.
func (s Subscription) ID() string {
	q := url.Values{}
	if s.Dashboard {
		q.Set("dashboard", s.DashboardKnown)
	}
	if s.Conversation != "" {
		q.Set("conversation", s.Conversation)
		q.Set("after", strconv.FormatInt(s.After, 10))
		q.Set("known", s.Known)
		q.Set("epoch", s.Epoch)
	}
	return q.Encode()
}
