package stream

import (
	"bufio"
	"compress/gzip"
	"context"
	"crypto/rand"
	"encoding/base64"
	"encoding/json"
	"fmt"
	"io"
	"net"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
	"time"

	"github.com/guiyuanju/overlook/remote/internal/bridge"
	"github.com/guiyuanju/overlook/remote/internal/store"
)

type frame struct {
	id, event, data string
	comment         bool
}

type reader struct {
	t    *testing.T
	resp *http.Response
	r    *bufio.Reader
}

func (r *reader) next(timeout time.Duration) (frame, bool) {
	r.t.Helper()
	type res struct {
		f   frame
		err error
	}
	ch := make(chan res, 1)
	go func() {
		var f frame
		for {
			line, err := r.r.ReadString('\n')
			if err != nil {
				ch <- res{err: err}
				return
			}
			line = strings.TrimRight(line, "\n")
			switch {
			case line == "":
				if f.event != "" || f.comment {
					ch <- res{f: f}
					return
				}
			case strings.HasPrefix(line, ":"):
				f.comment = true
			case strings.HasPrefix(line, "id: "):
				f.id = line[4:]
			case strings.HasPrefix(line, "event: "):
				f.event = line[7:]
			case strings.HasPrefix(line, "data: "):
				f.data = line[6:]
			}
		}
	}()
	select {
	case x := <-ch:
		return x.f, x.err == nil
	case <-time.After(timeout):
		return frame{}, false
	}
}

func (r *reader) expect(event string) frame {
	r.t.Helper()
	f, ok := r.next(2 * time.Second)
	if !ok || f.event != event {
		r.t.Fatalf("got %+v (ok=%v), want event %s", f, ok, event)
	}
	return f
}

func (r *reader) quiet(d time.Duration) {
	r.t.Helper()
	if f, ok := r.next(d); ok {
		r.t.Fatalf("unexpected frame %+v", f)
	}
}

type fixture struct {
	t   *testing.T
	st  *store.Store
	hub *Hub
	srv *httptest.Server
}

func setup(t *testing.T, opts Options) *fixture {
	t.Helper()
	st := store.New(store.Options{Dir: t.TempDir()})
	hub := NewHub(st, opts)
	st.OnChange(hub.Notify)
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		sub, err := ParseSubscription(r.URL.Query(), r.Header.Get("Last-Event-ID"))
		if err != nil {
			http.Error(w, err.Error(), 400)
			return
		}
		if err := hub.Serve(r.Context(), w, r, sub); err != nil {
			http.Error(w, err.Error(), 429)
		}
	}))
	t.Cleanup(func() {
		hub.Close()
		srv.Close()
	})
	st.Connected(bridge.HelloParams{Epoch: "e"})
	st.Sync(bridge.SyncParams{
		Dashboard:     []bridge.Node{{Key: "g", Kind: "group", Title: "G"}},
		Conversations: []bridge.Conversation{{ID: "c1", Provider: "p", Status: "idle", Controls: bridge.Controls{Actions: []string{"close"}}}},
	})
	return &fixture{t: t, st: st, hub: hub, srv: srv}
}

func (f *fixture) open(query string, header http.Header) *reader {
	f.t.Helper()
	req, _ := http.NewRequest("GET", f.srv.URL+"/?"+query, nil)
	for k, v := range header {
		req.Header[k] = v
	}
	tr := &http.Transport{DisableCompression: true}
	resp, err := (&http.Client{Transport: tr}).Do(req)
	if err != nil {
		f.t.Fatal(err)
	}
	f.t.Cleanup(func() { resp.Body.Close() })
	var body io.Reader = resp.Body
	if resp.Header.Get("Content-Encoding") == "gzip" {
		gz, err := gzip.NewReader(resp.Body)
		if err != nil {
			f.t.Fatal(err)
		}
		body = gz
	}
	return &reader{t: f.t, resp: resp, r: bufio.NewReader(body)}
}

var fast = Options{Coalesce: 30 * time.Millisecond, Heartbeat: time.Hour, MaxStreams: 3}

func TestCatchUpAndQuiet(t *testing.T) {
	f := setup(t, fast)
	r := f.open("dashboard=", nil)
	var hello store.StreamHello
	_ = json.Unmarshal([]byte(r.expect(EventHello).data), &hello)
	if hello.Protocol != 3 || hello.Emacs != store.EmacsOnline || hello.Epoch != f.st.Epoch() {
		t.Fatalf("hello %+v", hello)
	}
	d := r.expect(EventDashboard)
	if !strings.Contains(d.id, "dashboard="+f.st.DashboardKnown()) {
		t.Fatalf("dashboard id %q", d.id)
	}

	current := f.open("dashboard="+f.st.DashboardKnown(), nil)
	current.expect(EventHello)
	current.quiet(100 * time.Millisecond)

	snap, _ := f.st.Snapshot("c1")
	conv := f.open(Subscription{Conversation: "c1", After: snap.Seq, Known: snap.Known, Epoch: snap.Epoch}.ID(), nil)
	conv.expect(EventHello)
	conv.quiet(100 * time.Millisecond)
}

func TestCoalescedConversationEvents(t *testing.T) {
	f := setup(t, fast)
	snap, _ := f.st.Snapshot("c1")
	r := f.open(Subscription{Conversation: "c1", After: snap.Seq, Known: snap.Known, Epoch: snap.Epoch}.ID(), nil)
	r.expect(EventHello)
	for _, chunk := range []string{"a", "b", "c"} {
		f.st.Event(bridge.Event{Conversation: "c1", At: time.Now(), Type: bridge.EventText, Text: chunk})
	}
	ev := r.expect(EventConversation)
	var d store.ConversationDelta
	_ = json.Unmarshal([]byte(ev.data), &d)
	if len(d.Items) != 1 || d.Items[0].Text != "abc" || d.Conversation == nil {
		t.Fatalf("delta %s", ev.data)
	}
	f.st.Event(bridge.Event{Conversation: "c1", At: time.Now(), Type: bridge.EventText, Text: "d"})
	ev = r.expect(EventConversation)
	d = store.ConversationDelta{}
	_ = json.Unmarshal([]byte(ev.data), &d)
	if len(d.Items) != 1 || d.Items[0].Text != "d" || d.Items[0].Offset != 3 || d.Conversation != nil {
		t.Fatalf("suffix delta %s", ev.data)
	}

	resumed := f.open("", http.Header{"Last-Event-Id": {ev.id}})
	resumed.expect(EventHello)
	resumed.quiet(100 * time.Millisecond)
}

func TestResetGoneAndStatus(t *testing.T) {
	var earlier int
	opts := fast
	opts.Earlier = func(ctx context.Context, snap *store.ConversationSnapshot) {
		earlier++
		snap.Earlier = &store.Earlier{Reply: "r", Transcript: "t"}
	}
	f := setup(t, opts)
	r := f.open("conversation=c1&dashboard=", nil)
	r.expect(EventHello)
	r.expect(EventDashboard)
	reset := r.expect(EventConversation)
	if !strings.Contains(reset.data, `"reset":true`) || !strings.Contains(reset.data, `"earlier":{"reply":"r"`) || earlier != 1 {
		t.Fatalf("reset %s", reset.data)
	}

	f.st.Disconnected()
	if ev := r.expect(EventStatus); ev.data != `{"emacs":"offline"}` {
		t.Fatalf("status %s", ev.data)
	}
	f.st.Connected(bridge.HelloParams{Epoch: "e2"})
	f.st.Sync(bridge.SyncParams{Dashboard: []bridge.Node{{Key: "g", Kind: "group", Title: "G2"}}})
	seen := map[string]string{}
	for range 3 {
		ev, ok := r.next(2 * time.Second)
		if !ok {
			t.Fatalf("missing events, got %v", seen)
		}
		seen[ev.event] = ev.data
	}
	if !strings.Contains(seen[EventStatus], `"epoch":"`+f.st.Epoch()+`"`) || seen[EventGone] != `{"conversation":"c1"}` || seen[EventDashboard] == "" {
		t.Fatalf("events %v", seen)
	}

	only := f.open("conversation=c1", nil)
	if only.resp.StatusCode != 200 {
		t.Fatal(only.resp.Status)
	}
	only.expect(EventHello)
	only.expect(EventGone)
	if _, ok := only.next(time.Second); ok {
		t.Fatal("conversation-only stream stayed open after gone")
	}
}

func TestGzipHeartbeatAndLimit(t *testing.T) {
	opts := fast
	opts.Compress = true
	opts.Heartbeat = 50 * time.Millisecond
	f := setup(t, opts)
	r := f.open("dashboard=", http.Header{"Accept-Encoding": {"gzip"}})
	if r.resp.Header.Get("Content-Encoding") != "gzip" {
		t.Fatal("stream not gzip encoded")
	}
	r.expect(EventHello)
	r.expect(EventDashboard)
	if c, ok := r.next(time.Second); !ok || !c.comment {
		t.Fatalf("no heartbeat: %+v", c)
	}
	plain := f.open("dashboard=", http.Header{"Accept-Encoding": {"gzip;q=0"}})
	if plain.resp.Header.Get("Content-Encoding") != "" {
		t.Fatal("q=0 still compressed")
	}
	extra := f.open("dashboard=", nil)
	extra.expect(EventHello)
	if over := f.open("dashboard=", nil); over.resp.StatusCode != 429 {
		t.Fatalf("fourth stream: %s", over.resp.Status)
	}
	if f.hub.Count() != 3 {
		t.Fatalf("count %d", f.hub.Count())
	}
}

func TestAcceptsGzip(t *testing.T) {
	tests := map[string]bool{"gzip": true, "br, gzip;q=0.5": true, "gzip;q=0": false, "br": false, "": false, "*": true}
	for header, want := range tests {
		r := httptest.NewRequest("GET", "/", nil)
		r.Header.Set("Accept-Encoding", header)
		if got := AcceptsGzip(r); got != want {
			t.Errorf("%q: %v", header, got)
		}
	}
}

func TestStalledClientIsDroppedWithoutHoldingOthers(t *testing.T) {
	opts := fast
	opts.WriteTimeout = 200 * time.Millisecond
	f := setup(t, opts)
	snap, _ := f.st.Snapshot("c1")
	sub := Subscription{Conversation: "c1", After: snap.Seq, Known: snap.Known, Epoch: snap.Epoch}.ID()
	conn, err := net.Dial("tcp", strings.TrimPrefix(f.srv.URL, "http://"))
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { conn.Close() })
	_ = conn.(*net.TCPConn).SetReadBuffer(4096)
	fmt.Fprintf(conn, "GET /?%s HTTP/1.1\r\nHost: test\r\n\r\n", sub)
	stalled := bufio.NewReader(conn)
	for {
		line, err := stalled.ReadString('\n')
		if err != nil {
			t.Fatal(err)
		}
		if strings.HasPrefix(line, "event: hello") {
			break
		}
	}
	healthy := f.open(sub, nil)
	healthy.expect(EventHello)

	random := make([]byte, 384<<10)
	for i := 0; f.hub.Count() > 1; i++ {
		if i == 64 {
			t.Fatalf("stalled stream still open after %d MiB", i*len(random)>>20)
		}
		_, _ = rand.Read(random)
		f.st.Event(bridge.Event{Conversation: "c1", At: time.Now(), Type: bridge.EventText, Text: base64.StdEncoding.EncodeToString(random)})
		start := time.Now()
		healthy.expect(EventConversation)
		if waited := time.Since(start); waited > time.Second {
			t.Fatalf("a stalled reader held the healthy one for %v", waited)
		}
	}
	f.st.Event(bridge.Event{Conversation: "c1", At: time.Now(), Type: bridge.EventText, Text: "after"})
	healthy.expect(EventConversation)
}
