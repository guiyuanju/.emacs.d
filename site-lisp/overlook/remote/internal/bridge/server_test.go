package bridge

import (
	"bufio"
	"context"
	"encoding/json"
	"errors"
	"net"
	"os"
	"path/filepath"
	"strings"
	"sync"
	"testing"
	"time"
)

// socketPath returns a short socket path; macOS limits them to 104 bytes.
func socketPath(t *testing.T) string {
	t.Helper()
	dir, err := os.MkdirTemp("", "ovb")
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { os.RemoveAll(dir) })
	return filepath.Join(dir, "sub", "bridge.sock")
}

type recorder struct {
	mu     sync.Mutex
	calls  []string
	epoch  string
	events []Event
}

func (r *recorder) add(s string) {
	r.mu.Lock()
	r.calls = append(r.calls, s)
	r.mu.Unlock()
}

func (r *recorder) Connected(h HelloParams) string {
	r.add("connected:" + h.Epoch)
	return "hist-1"
}
func (r *recorder) Sync(SyncParams)                       { r.add("sync") }
func (r *recorder) SetDashboard(DashboardSetParams)       { r.add("dashboard") }
func (r *recorder) SetConversation(ConversationSetParams) { r.add("conversation") }
func (r *recorder) RemoveConversation(ConversationParams) { r.add("remove") }
func (r *recorder) Event(e Event) {
	r.mu.Lock()
	r.events = append(r.events, e)
	r.mu.Unlock()
	r.add("event")
}
func (r *recorder) Disconnected() { r.add("disconnected") }

func (r *recorder) snapshot() []string {
	r.mu.Lock()
	defer r.mu.Unlock()
	return append([]string(nil), r.calls...)
}

func (r *recorder) waitFor(t *testing.T, want string) {
	t.Helper()
	deadline := time.Now().Add(2 * time.Second)
	for time.Now().Before(deadline) {
		for _, c := range r.snapshot() {
			if c == want {
				return
			}
		}
		time.Sleep(5 * time.Millisecond)
	}
	t.Fatalf("no %q in %v", want, r.snapshot())
}

type client struct {
	t    *testing.T
	conn net.Conn
	r    *bufio.Reader
}

func dial(t *testing.T, path string) *client {
	t.Helper()
	conn, err := net.Dial("unix", path)
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { conn.Close() })
	return &client{t: t, conn: conn, r: bufio.NewReader(conn)}
}

func (c *client) send(line string) {
	c.t.Helper()
	if _, err := c.conn.Write([]byte(line + "\n")); err != nil {
		c.t.Fatal(err)
	}
}

func (c *client) recv() Message {
	c.t.Helper()
	_ = c.conn.SetReadDeadline(time.Now().Add(2 * time.Second))
	line, err := c.r.ReadBytes('\n')
	if err != nil {
		c.t.Fatalf("recv: %v", err)
	}
	var m Message
	if err := json.Unmarshal(line, &m); err != nil {
		c.t.Fatalf("recv %q: %v", line, err)
	}
	return m
}

func (c *client) hello(epoch string) HelloResult {
	c.t.Helper()
	c.send(`{"jsonrpc":"2.0","id":"hello-1","method":"hello","params":{"protocol":1,"epoch":"` + epoch + `","emacs":"31","pid":1}}`)
	m := c.recv()
	if m.Error != nil {
		c.t.Fatalf("hello: %v", m.Error)
	}
	var r HelloResult
	_ = json.Unmarshal(m.Result, &r)
	return r
}

func start(t *testing.T) (*Server, *recorder, string) {
	t.Helper()
	path := socketPath(t)
	rec := &recorder{}
	s := NewServer(path, "test", rec, nil)
	ctx, cancel := context.WithCancel(context.Background())
	done := make(chan struct{})
	if err := s.Listen(); err != nil {
		t.Fatal(err)
	}
	go func() {
		defer close(done)
		_ = s.Serve(ctx)
	}()
	t.Cleanup(func() {
		cancel()
		<-done
	})
	return s, rec, path
}

func TestSocketPermissionsAndStale(t *testing.T) {
	path := socketPath(t)
	if err := os.MkdirAll(filepath.Dir(path), 0o755); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(path, nil, 0o644); err != nil {
		t.Fatal(err)
	}
	s := NewServer(path, "test", &recorder{}, nil)
	if err := s.Listen(); err != nil {
		t.Fatalf("stale socket not replaced: %v", err)
	}
	defer s.ln.Close()
	fi, _ := os.Stat(path)
	di, _ := os.Stat(filepath.Dir(path))
	if fi.Mode().Perm() != 0o600 || di.Mode().Perm() != 0o700 {
		t.Fatalf("socket %v, dir %v", fi.Mode().Perm(), di.Mode().Perm())
	}
	if err := NewServer(path, "test", &recorder{}, nil).Listen(); err == nil {
		t.Fatal("a second daemon took a live socket")
	}
}

func TestHelloGating(t *testing.T) {
	tests := []struct {
		name, line, wantProblem string
		wantCode                int
	}{
		{"request before hello", `{"jsonrpc":"2.0","id":"x","method":"sync","params":{}}`, "hello_required", 400},
		{"wrong protocol", `{"jsonrpc":"2.0","id":"h","method":"hello","params":{"protocol":2,"epoch":"e"}}`, "protocol_mismatch", 409},
		{"parse error with id", `{"jsonrpc":"2.0","id":"p","method":`, "", CodeParseError},
	}
	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			_, _, path := start(t)
			c := dial(t, path)
			c.send(tt.line)
			m := c.recv()
			if m.Error == nil || m.Error.Code != tt.wantCode || m.Error.Problem() != tt.wantProblem {
				t.Fatalf("got %+v", m.Error)
			}
		})
	}
}

func TestLifecycleAndCalls(t *testing.T) {
	s, rec, path := start(t)
	if s.Online() {
		t.Fatal("online before any connection")
	}
	c := dial(t, path)
	c.send(`{"jsonrpc":"2.0","method":"sync","params":{}}`)
	res := c.hello("e1")
	if res.HistoryEpoch != "hist-1" || res.Protocol != 1 || res.MaxMessageBytes != MaxInboundLine {
		t.Fatalf("hello result %+v", res)
	}
	c.send(`{"jsonrpc":"2.0","method":"agent.event","params":{"conversation":"c","at":"2026-11-13T08:00:00.000Z","type":"text","text":"dropped"}}`)
	c.send(`{"jsonrpc":"2.0","method":"sync","params":{"dashboard":[],"conversations":[]}}`)
	c.send(`{"jsonrpc":"2.0","method":"agent.event","params":{"conversation":"c","at":"2026-11-13T08:00:00.000Z","type":"text","text":"kept"}}`)
	rec.waitFor(t, "event")
	if got := strings.Join(rec.snapshot(), ","); got != "connected:e1,sync,event" {
		t.Fatalf("calls %s", got)
	}
	if !s.Online() {
		t.Fatal("not online after sync")
	}

	errc := make(chan error, 1)
	var out PromptResult
	go func() {
		var err error
		out, err = s.Prompt(context.Background(), PromptParams{Conversation: "c", Text: "hi"})
		errc <- err
	}()
	req := c.recv()
	if req.Method != MethodPrompt || !strings.Contains(string(req.Params), `"text":"hi"`) {
		t.Fatalf("request %+v", req)
	}
	c.send(`{"jsonrpc":"2.0","id":` + string(req.ID) + `,"result":{"delivery":"queued","queueId":"q1"}}`)
	if err := <-errc; err != nil || out.QueueID != "q1" {
		t.Fatalf("prompt = %+v, %v", out, err)
	}

	go func() { errc <- s.Unqueue(context.Background(), UnqueueParams{Conversation: "c", QueueID: "q1"}) }()
	req = c.recv()
	c.send(`{"jsonrpc":"2.0","id":` + string(req.ID) + `,"error":{"code":409,"message":"sent","data":{"problem":"already_sent"}}}`)
	var be *Error
	if err := <-errc; !errors.As(err, &be) || be.Problem() != "already_sent" {
		t.Fatalf("unqueue error %v", err)
	}

	ctx, cancel := context.WithTimeout(context.Background(), 20*time.Millisecond)
	defer cancel()
	if err := s.Ping(ctx); !errors.Is(err, ErrTimeout) {
		t.Fatalf("ping without answer: %v", err)
	}
	_ = c.recv()

	if err := s.Seen(ConversationParams{Conversation: "c"}); err != nil {
		t.Fatal(err)
	}
	if m := c.recv(); m.Method != MethodSeen || len(m.ID) != 0 {
		t.Fatalf("seen %+v", m)
	}

	go func() { errc <- s.Retry(context.Background(), ConversationParams{Conversation: "c"}) }()
	_ = c.recv()
	c.conn.Close()
	if err := <-errc; !errors.Is(err, ErrOffline) {
		t.Fatalf("pending call after disconnect: %v", err)
	}
	rec.waitFor(t, "disconnected")
	if err := s.Ping(context.Background()); !errors.Is(err, ErrOffline) {
		t.Fatalf("call while offline: %v", err)
	}
}

func TestReplacementAndOverlong(t *testing.T) {
	s, rec, path := start(t)
	a := dial(t, path)
	a.hello("e1")
	a.send(`{"jsonrpc":"2.0","method":"sync","params":{}}`)
	rec.waitFor(t, "sync")
	b := dial(t, path)
	b.hello("e1")
	if _, err := a.r.ReadByte(); err == nil {
		t.Fatal("replaced connection still open")
	}
	b.send(`{"jsonrpc":"2.0","method":"sync","params":{}}`)
	b.send(`{"jsonrpc":"2.0","method":"dashboard.set","params":{"sections":"not an array"}}`)
	if m := b.recv(); m.Method != MethodResync {
		t.Fatalf("invalid params: got %+v, want resync", m)
	}
	for _, c := range rec.snapshot() {
		if c == "disconnected" {
			t.Fatal("replacement reported a disconnect")
		}
	}
	if !s.Online() {
		t.Fatal("offline after replacement sync")
	}

	big := strings.Repeat("x", MaxInboundLine+10)
	b.send(`{"jsonrpc":"2.0","id":"r1","method":"hello","params":{"pad":"` + big + `"}}`)
	if m := b.recv(); m.Error == nil || m.Error.Problem() != "request_too_large" || string(m.ID) != `"r1"` {
		t.Fatalf("over-long request: %+v", m)
	}
	b.send(`{"jsonrpc":"2.0","method":"agent.event","params":{"text":"` + big + `"}}`)
	if m := b.recv(); m.Method != MethodResync {
		t.Fatalf("over-long notification: %+v", m)
	}
}

func TestEnvelopeHead(t *testing.T) {
	tests := []struct {
		in, id, method string
	}{
		{`{"jsonrpc":"2.0","id":7,"method":"x","params":{"id":"inner"`, "7", "x"},
		{`{"method":"agent.event","params":{"id":"tool"},"jsonrpc"`, "", "agent.event"},
		{`not json`, "", ""},
	}
	for _, tt := range tests {
		id, method := envelopeHead([]byte(tt.in))
		if string(id) != tt.id || method != tt.method {
			t.Errorf("envelopeHead(%q) = %s, %q", tt.in, id, method)
		}
	}
}
