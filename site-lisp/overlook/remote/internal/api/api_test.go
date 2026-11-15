package api

import (
	"bytes"
	"context"
	"encoding/json"
	"io"
	"net/http"
	"net/http/httptest"
	"os"
	"slices"
	"strings"
	"sync"
	"sync/atomic"
	"testing"
	"time"

	"github.com/andybalholm/brotli"

	"github.com/guiyuanju/overlook/remote/internal/bridge"
	"github.com/guiyuanju/overlook/remote/internal/store"
	"github.com/guiyuanju/overlook/remote/internal/stream"
)

const token = "test-token"

var png = []byte("\x89PNG\r\n\x1a\nimage-bytes")

// emacs is a scriptable api.Emacs.
type emacs struct {
	mu      sync.Mutex
	calls   []string
	actions []bridge.ActionParams
	cmds    []bridge.CommandParams
	seen    []string
	delay   time.Duration
	err     error
	prompts atomic.Int32
	attach  func(bridge.AttachParams) (bridge.AttachResult, error)
	action  func(bridge.ActionParams) bridge.ActionOutcome
	command func(bridge.CommandParams) bridge.CommandOutcome
}

func (e *emacs) record(name string) error {
	e.mu.Lock()
	e.calls = append(e.calls, name)
	delay, err := e.delay, e.err
	e.mu.Unlock()
	time.Sleep(delay)
	return err
}

func (e *emacs) set(delay time.Duration, err error) {
	e.mu.Lock()
	e.delay, e.err = delay, err
	e.mu.Unlock()
}

func (e *emacs) Prompt(_ context.Context, p bridge.PromptParams) (bridge.PromptResult, error) {
	e.prompts.Add(1)
	if err := e.record("prompt:" + p.Text); err != nil {
		return bridge.PromptResult{}, err
	}
	return bridge.PromptResult{Delivery: bridge.DeliveryQueued, QueueID: "q1"}, nil
}
func (e *emacs) Unqueue(context.Context, bridge.UnqueueParams) error { return e.record("unqueue") }
func (e *emacs) Retry(context.Context, bridge.ConversationParams) error {
	return e.record("retry")
}
func (e *emacs) Action(_ context.Context, p bridge.ActionParams) (bridge.ActionOutcome, error) {
	e.mu.Lock()
	e.actions = append(e.actions, p)
	e.mu.Unlock()
	if err := e.record("action"); err != nil {
		return bridge.ActionOutcome{}, err
	}
	return e.action(p), nil
}
func (e *emacs) Choose(context.Context, bridge.ChooseParams) error { return e.record("choose") }
func (e *emacs) Answer(context.Context, bridge.AnswerParams) error { return e.record("answer") }
func (e *emacs) Attach(_ context.Context, p bridge.AttachParams) (bridge.AttachResult, error) {
	if err := e.record("attach"); err != nil {
		return bridge.AttachResult{}, err
	}
	return e.attach(p)
}
func (e *emacs) Earlier(context.Context, bridge.ConversationParams) (bridge.EarlierResult, error) {
	return bridge.EarlierResult{Reply: "last reply", Transcript: "tail"}, e.record("earlier")
}
func (e *emacs) Command(_ context.Context, p bridge.CommandParams) (bridge.CommandOutcome, error) {
	e.mu.Lock()
	e.cmds = append(e.cmds, p)
	e.mu.Unlock()
	if err := e.record("command"); err != nil {
		return bridge.CommandOutcome{}, err
	}
	return e.command(p), nil
}
func (e *emacs) Diff(context.Context, bridge.DiffParams) (bridge.DiffResult, error) {
	return bridge.DiffResult{Diff: "--- a\n+++ a\n"}, e.record("diff")
}
func (e *emacs) Seen(p bridge.ConversationParams) error {
	e.mu.Lock()
	e.seen = append(e.seen, p.Conversation)
	e.mu.Unlock()
	return nil
}

type env struct {
	t     *testing.T
	st    *store.Store
	emacs *emacs
	srv   *httptest.Server
}

func setup(t *testing.T) *env {
	t.Helper()
	st := store.New(store.Options{Dir: t.TempDir()})
	hub := stream.NewHub(st, stream.Options{Coalesce: 10 * time.Millisecond})
	st.OnChange(hub.Notify)
	e := &emacs{
		action: func(p bridge.ActionParams) bridge.ActionOutcome {
			if len(p.Confirmed) == 0 {
				return bridge.ActionOutcome{Outcome: bridge.OutcomeConfirm, Question: "Sure?"}
			}
			if len(p.Confirmed) == 1 {
				return bridge.ActionOutcome{Outcome: bridge.OutcomeConfirm, Question: "Really?"}
			}
			return bridge.ActionOutcome{Outcome: bridge.OutcomeDone, Closed: true}
		},
		command: func(p bridge.CommandParams) bridge.CommandOutcome {
			if p.Name == "kill" && len(p.Confirmed) == 0 {
				return bridge.CommandOutcome{Outcome: bridge.OutcomeConfirm, Question: "Kill?"}
			}
			return bridge.CommandOutcome{Outcome: bridge.OutcomeDone, Draft: p.Text}
		},
	}
	e.attach = func(p bridge.AttachParams) (bridge.AttachResult, error) {
		data, err := os.ReadFile(p.Path)
		if err != nil || !bytes.Equal(data, png) {
			return bridge.AttachResult{}, bridge.NewError(500, "internal_error", "upload missing")
		}
		return bridge.AttachResult{Text: "@" + p.Name}, nil
	}
	auth := func(next http.Handler) http.Handler {
		return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
			if r.Header.Get("Authorization") != "Bearer "+token {
				WriteProblem(w, NewProblem(401, CodeUnauthorized, "no"))
				return
			}
			next.ServeHTTP(w, r)
		})
	}
	srv := httptest.NewServer(New(Deps{Store: st, Emacs: e, Hub: hub, Auth: auth}).Handler())
	t.Cleanup(func() {
		hub.Close()
		srv.Close()
	})
	st.Connected(bridge.HelloParams{Epoch: "e"})
	st.Sync(bridge.SyncParams{
		Dashboard: []bridge.Node{{Key: "p", Kind: "project", Title: "P", Diff: true, Commands: []bridge.Command{
			{Name: "kill", Label: "Kill", Confirm: true},
			{Name: "prompt", Label: "Prompt", Input: "What?"},
			{Name: "switch", Label: "Switch", Options: []string{"a", "b"}},
		}, Children: []bridge.Node{{Key: "n", Kind: "text", Title: "plain"}}}},
		Conversations: []bridge.Conversation{
			{ID: "c1", Provider: "claude", Status: "idle", CanAttach: true, Root: "/r",
				Form:     &bridge.Form{ID: "f1", Message: "Q", Answerable: true},
				Controls: bridge.Controls{Steer: true, Actions: []string{"close", "stop", "model"}, Settings: []bridge.Setting{{ID: "model", Label: "Model", Value: "a"}}}},
			{ID: "c2", Provider: "codex", Status: "idle", Controls: bridge.Controls{Actions: []string{"close"}}},
		},
	})
	return &env{t: t, st: st, emacs: e, srv: srv}
}

type result struct {
	status int
	header http.Header
	body   []byte
}

func (r result) problem() Problem {
	var p Problem
	_ = json.Unmarshal(r.body, &p)
	return p
}

func (e *env) do(method, path string, body any, header ...string) result {
	e.t.Helper()
	var rd io.Reader
	switch b := body.(type) {
	case nil:
	case string:
		rd = strings.NewReader(b)
	case []byte:
		rd = bytes.NewReader(b)
	default:
		data, _ := json.Marshal(b)
		rd = bytes.NewReader(data)
	}
	req, _ := http.NewRequest(method, e.srv.URL+path, rd)
	req.Header.Set("Authorization", "Bearer "+token)
	for i := 0; i+1 < len(header); i += 2 {
		if header[i+1] == "" {
			req.Header.Del(header[i])
		} else {
			req.Header.Set(header[i], header[i+1])
		}
	}
	resp, err := (&http.Client{Transport: &http.Transport{DisableCompression: true}}).Do(req)
	if err != nil {
		e.t.Fatal(err)
	}
	defer resp.Body.Close()
	data, _ := io.ReadAll(resp.Body)
	if resp.Header.Get("Content-Encoding") == "br" {
		data, _ = io.ReadAll(brotli.NewReader(bytes.NewReader(data)))
	}
	return result{resp.StatusCode, resp.Header, data}
}

const api = "/overlook/api"

func TestRoutingAndAuth(t *testing.T) {
	e := setup(t)
	tests := []struct {
		name, method, path string
		header             []string
		status             int
		code, allow        string
	}{
		{"wrong method", "PUT", api + "/dashboard", nil, 405, CodeMethodNotAllowed, "GET, HEAD"},
		{"post on read", "POST", api + "/conversations/c1/read", nil, 405, CodeMethodNotAllowed, "PUT"},
		{"unknown route", "GET", api + "/nope", nil, 404, CodeRouteMissing, ""},
		{"no token", "GET", api + "/dashboard", []string{"Authorization", ""}, 401, CodeUnauthorized, ""},
		{"bad token", "GET", api + "/dashboard", []string{"Authorization", "Bearer nope"}, 401, CodeUnauthorized, ""},
		{"stream bad query", "GET", api + "/stream", nil, 400, CodeInvalidQuery, ""},
		{"stream missing conversation", "GET", api + "/stream?conversation=zz", nil, 404, CodeConversationMissing, ""},
		{"history no epoch", "GET", api + "/conversations/c1/history?before=5", nil, 400, CodeInvalidQuery, ""},
		{"history bad limit", "GET", api + "/conversations/c1/history?before=5&epoch=x&limit=101", nil, 400, CodeInvalidQuery, ""},
		{"history expired", "GET", api + "/conversations/c1/history?before=5&epoch=x", nil, 409, CodeHistoryExpired, ""},
		{"image bad id", "GET", api + "/images/zzz", nil, 404, CodeImageMissing, ""},
		{"image unknown", "GET", api + "/images/0123456789abcdef", nil, 404, CodeImageMissing, ""},
		{"diff unknown node", "GET", api + "/nodes/0123456789abcdef/diff", nil, 404, CodeNodeMissing, ""},
		{"conversation missing", "GET", api + "/conversations/zz", nil, 404, CodeConversationMissing, ""},
	}
	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			r := e.do(tt.method, tt.path, nil, tt.header...)
			p := r.problem()
			if r.status != tt.status || p.Code != tt.code || p.Status != tt.status || p.Type != "urn:overlook:problem:"+tt.code {
				t.Fatalf("got %d %s", r.status, r.body)
			}
			if r.header.Get("Content-Type") != "application/problem+json" || r.header.Get("Overlook-Protocol") != "3" {
				t.Fatalf("headers %v", r.header)
			}
			if tt.allow != "" && r.header.Get("Allow") != tt.allow {
				t.Fatalf("Allow %q", r.header.Get("Allow"))
			}
			if tt.status == 401 && r.header.Get("WWW-Authenticate") != "Bearer" {
				t.Fatal("no WWW-Authenticate")
			}
		})
	}
	h := e.do("GET", "/overlook/healthz", nil, "Authorization", "")
	if h.status != 200 || string(h.body) != `{"status":"ok","emacs":"online"}` {
		t.Fatalf("healthz %d %s", h.status, h.body)
	}
}

func TestReadsETagsAndCompression(t *testing.T) {
	e := setup(t)
	d := e.do("GET", api+"/dashboard", nil, "Accept-Encoding", "br")
	var dash store.Dashboard
	if err := json.Unmarshal(d.body, &dash); err != nil || d.status != 200 || dash.Known == "" {
		t.Fatalf("dashboard %d %s", d.status, d.body)
	}
	if d.header.Get("ETag") != `"`+dash.Known+`"` {
		t.Fatalf("etag %q", d.header.Get("ETag"))
	}
	if r := e.do("GET", api+"/dashboard", nil, "If-None-Match", d.header.Get("ETag")); r.status != 304 || len(r.body) != 0 {
		t.Fatalf("dashboard revalidation %d", r.status)
	}
	if r := e.do("GET", api+"/dashboard?known="+dash.Known, nil); !strings.Contains(string(r.body), `"sections":[{"same":`) {
		t.Fatalf("known cursor %s", r.body)
	}

	l := e.do("GET", api+"/conversations", nil)
	if l.status != 200 || !strings.Contains(string(l.body), `"id":"c1"`) || strings.Contains(string(l.body), `"root"`) {
		t.Fatalf("list %s", l.body)
	}
	if r := e.do("GET", api+"/conversations", nil, "If-None-Match", l.header.Get("ETag")); r.status != 304 {
		t.Fatalf("list revalidation %d", r.status)
	}

	c := e.do("GET", api+"/conversations/c1", nil)
	var snap store.ConversationSnapshot
	_ = json.Unmarshal(c.body, &snap)
	if snap.Earlier == nil || snap.Earlier.Reply != "last reply" || len(snap.Items) != 0 {
		t.Fatalf("snapshot %s", c.body)
	}
	if c.header.Get("ETag") != `"`+snap.Epoch+".0."+snap.Known+`"` {
		t.Fatalf("snapshot etag %q", c.header.Get("ETag"))
	}
	e.st.Event(bridge.Event{Conversation: "c1", At: time.Now(), Type: bridge.EventText, Text: "hello"})
	if r := e.do("GET", api+"/conversations/c1", nil, "If-None-Match", c.header.Get("ETag")); r.status != 200 {
		t.Fatalf("stale etag answered %d", r.status)
	}
}

func TestPromptValidation(t *testing.T) {
	e := setup(t)
	path := api + "/conversations/c1/prompts"
	tests := []struct {
		name   string
		body   any
		header []string
		status int
		code   string
	}{
		{"invalid json", `{"text":`, nil, 400, CodeInvalidJSON},
		{"trailing data", `{"text":"a"} {}`, nil, 400, CodeInvalidJSON},
		{"unknown field", `{"text":"a","queued":true}`, nil, 400, CodeInvalidBody},
		{"wrong type", `{"text":5}`, nil, 400, CodeInvalidField},
		{"missing text", `{}`, nil, 400, CodeInvalidField},
		{"blank text", `{"text":"  \n"}`, nil, 400, CodeEmptyText},
		{"bad key", `{"text":"a"}`, []string{"Idempotency-Key", "has space"}, 400, CodeInvalidIdempotencyKey},
		{"too large", `{"text":"` + strings.Repeat("x", MaxJSONBody) + `"}`, nil, 413, CodeRequestTooLarge},
		{"missing conversation", `{"text":"a"}`, nil, 0, ""},
	}
	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			p := path
			if tt.status == 0 {
				p, tt.status, tt.code = api+"/conversations/zz/prompts", 404, CodeConversationMissing
			}
			r := e.do("POST", p, tt.body, tt.header...)
			if r.status != tt.status || r.problem().Code != tt.code {
				t.Fatalf("got %d %s", r.status, r.body)
			}
		})
	}
	if n := e.emacs.prompts.Load(); n != 0 {
		t.Fatalf("invalid prompts reached Emacs %d times", n)
	}
}

func TestIdempotency(t *testing.T) {
	e := setup(t)
	path := api + "/conversations/c1/prompts"
	first := e.do("POST", path, `{"text":" hi "}`, "Idempotency-Key", "k1")
	if first.status != 200 || string(first.body) != `{"delivery":"queued","queueId":"q1"}` {
		t.Fatalf("first %d %s", first.status, first.body)
	}
	again := e.do("POST", path, `{"text":"hi"}`, "Idempotency-Key", "k1")
	if again.status != 200 || !bytes.Equal(again.body, first.body) || e.emacs.prompts.Load() != 1 {
		t.Fatalf("replay %d %s after %d calls", again.status, again.body, e.emacs.prompts.Load())
	}
	if r := e.do("POST", path, `{"text":"other"}`, "Idempotency-Key", "k1"); r.status != 409 || r.problem().Code != CodeIdempotencyConflict {
		t.Fatalf("conflict %d %s", r.status, r.body)
	}

	e.emacs.set(150*time.Millisecond, nil)
	var wg sync.WaitGroup
	results := make([]result, 3)
	for i := range results {
		wg.Add(1)
		go func() {
			defer wg.Done()
			results[i] = e.do("POST", path, `{"text":"concurrent"}`, "Idempotency-Key", "k2")
		}()
	}
	wg.Wait()
	for _, r := range results {
		if r.status != 200 {
			t.Fatalf("concurrent duplicate %d %s", r.status, r.body)
		}
	}
	if n := e.emacs.prompts.Load(); n != 2 {
		t.Fatalf("concurrent duplicates reached Emacs %d times in total", n)
	}

	old := bridge.Timeouts[bridge.MethodPrompt]
	bridge.Timeouts[bridge.MethodPrompt] = 30 * time.Millisecond
	defer func() { bridge.Timeouts[bridge.MethodPrompt] = old }()
	e.emacs.set(120*time.Millisecond, nil)
	if r := e.do("POST", path, `{"text":"slow"}`, "Idempotency-Key", "k3"); r.status != 504 || r.problem().Code != CodeEmacsTimeout {
		t.Fatalf("timeout %d %s", r.status, r.body)
	}
	time.Sleep(150 * time.Millisecond)
	e.emacs.set(0, nil)
	if r := e.do("POST", path, `{"text":"slow"}`, "Idempotency-Key", "k3"); r.status != 200 || e.emacs.prompts.Load() != 3 {
		t.Fatalf("late result not replayed: %d %s, %d calls", r.status, r.body, e.emacs.prompts.Load())
	}
}

func TestEmacsErrors(t *testing.T) {
	e := setup(t)
	tests := []struct {
		err    error
		status int
		code   string
	}{
		{bridge.ErrOffline, 503, CodeEmacsOffline},
		{bridge.NewError(409, "already_sent", "sent"), 409, CodeAlreadySent},
		{&bridge.Error{Code: 409, Message: "no"}, 409, CodeStateConflict},
		{&bridge.Error{Code: 500, Message: "boom"}, 500, CodeInternalError},
		{&bridge.Error{Code: bridge.CodeMethodNotFound, Message: "?"}, 500, CodeBridgeError},
	}
	for _, tt := range tests {
		e.emacs.set(0, tt.err)
		r := e.do("DELETE", api+"/conversations/c1/prompts/q1", nil)
		if r.status != tt.status || r.problem().Code != tt.code {
			t.Errorf("%v: got %d %s", tt.err, r.status, r.body)
		}
	}
	e.emacs.set(0, nil)
	for _, tt := range []struct{ method, path string }{
		{"DELETE", api + "/conversations/c1/prompts/q1"},
		{"POST", api + "/conversations/c1/prompts/retry"},
	} {
		if r := e.do(tt.method, tt.path, nil); r.status != 204 || len(r.body) != 0 {
			t.Errorf("%s %s: %d %s", tt.method, tt.path, r.status, r.body)
		}
	}
}

func TestActionConfirmation(t *testing.T) {
	e := setup(t)
	path := api + "/conversations/c1/actions"
	for _, tt := range []struct {
		body string
		code string
	}{
		{`{"action":"fork"}`, CodeUnsupportedAction},
		{`{"action":"steer"}`, CodeEmptyText},
		{`{"action":"model"}`, CodeEmptyText},
		{`{}`, CodeInvalidField},
	} {
		if r := e.do("POST", path, tt.body); r.status != 400 || r.problem().Code != tt.code {
			t.Errorf("%s: %d %s", tt.body, r.status, r.body)
		}
	}

	var res ActionResult
	r := e.do("POST", path, `{"action":"close"}`, "Idempotency-Key", "close-1")
	_ = json.Unmarshal(r.body, &res)
	if res.Outcome != bridge.OutcomeConfirm || res.Question != "Sure?" || !slices.Equal(res.Confirmations, []string{"Sure?"}) || res.ConfirmationToken == "" {
		t.Fatalf("first %s", r.body)
	}
	forged := e.do("POST", path, map[string]any{"action": "close", "confirmations": []string{"Sure?"}, "confirmationToken": "bad"}, "Idempotency-Key", "close-1")
	if !strings.Contains(string(forged.body), `"question":"Sure?"`) {
		t.Fatalf("forged token was accepted: %s", forged.body)
	}
	r = e.do("POST", path, map[string]any{"action": "close", "confirmations": res.Confirmations, "confirmationToken": res.ConfirmationToken}, "Idempotency-Key", "close-1")
	_ = json.Unmarshal(r.body, &res)
	if res.Question != "Really?" || !slices.Equal(res.Confirmations, []string{"Sure?", "Really?"}) {
		t.Fatalf("second %s", r.body)
	}

	stale := res
	e.st.SetConversation(bridge.ConversationSetParams{Conversation: bridge.Conversation{ID: "c1", Provider: "claude", Status: "working", CanAttach: true,
		Brief: "ticking", Form: &bridge.Form{ID: "f1"}, Controls: bridge.Controls{Steer: true, Actions: []string{"close", "stop", "model"}}}})
	r = e.do("POST", path, map[string]any{"action": "close", "confirmations": stale.Confirmations, "confirmationToken": stale.ConfirmationToken})
	if !strings.Contains(string(r.body), `"question":"Sure?"`) {
		t.Fatalf("token survived a state change: %s", r.body)
	}
	r = e.do("POST", path, `{"action":"close"}`)
	_ = json.Unmarshal(r.body, &res)
	r = e.do("POST", path, map[string]any{"action": "close", "confirmations": res.Confirmations, "confirmationToken": res.ConfirmationToken})
	_ = json.Unmarshal(r.body, &res)
	done := e.do("POST", path, map[string]any{"action": "close", "confirmations": res.Confirmations, "confirmationToken": res.ConfirmationToken}, "Idempotency-Key", "close-2")
	if done.status != 200 || string(done.body) != `{"outcome":"done","closed":true}` {
		t.Fatalf("done %d %s", done.status, done.body)
	}
	e.st.RemoveConversation(bridge.ConversationParams{Conversation: "c1"})
	replay := e.do("POST", path, map[string]any{"action": "close"}, "Idempotency-Key", "close-2")
	if replay.status != 200 || !bytes.Equal(replay.body, done.body) {
		t.Fatalf("replayed close after removal: %d %s", replay.status, replay.body)
	}
}

func TestChoiceFormRead(t *testing.T) {
	e := setup(t)
	c := api + "/conversations/c1"
	tests := []struct {
		method, path string
		body         string
		status       int
		code         string
	}{
		{"POST", c + "/choice", `{"key":"allow"}`, 204, ""},
		{"POST", c + "/choice", `{"key":""}`, 400, CodeInvalidField},
		{"POST", c + "/forms/f1", `{"action":"accept","values":{"q":"a"}}`, 204, ""},
		{"POST", c + "/forms/f1", `{"action":"maybe"}`, 400, CodeInvalidField},
		{"POST", c + "/forms/f1", `{"action":"accept","values":[1]}`, 400, CodeInvalidField},
		{"POST", c + "/forms/old", `{"action":"decline"}`, 409, CodeStateConflict},
		{"PUT", c + "/read", `{"through":0}`, 400, CodeInvalidField},
		{"PUT", c + "/read", `{"through":1,"epoch":"old"}`, 409, CodeHistoryExpired},
	}
	for _, tt := range tests {
		r := e.do(tt.method, tt.path, tt.body)
		if r.status != tt.status || (tt.code != "" && r.problem().Code != tt.code) {
			t.Errorf("%s %s %s: %d %s", tt.method, tt.path, tt.body, r.status, r.body)
		}
	}
	e.st.Event(bridge.Event{Conversation: "c1", At: time.Now(), Type: bridge.EventText, Text: "reply"})
	r := e.do("PUT", c+"/read", map[string]any{"through": 99, "epoch": e.st.Epoch()})
	if r.status != 200 || string(r.body) != `{"readThrough":1,"unreadCount":0}` || !slices.Equal(e.emacs.seen, []string{"c1"}) {
		t.Fatalf("read %d %s seen %v", r.status, r.body, e.emacs.seen)
	}
}

func TestAttachments(t *testing.T) {
	e := setup(t)
	path := api + "/conversations/c1/attachments"
	tests := []struct {
		name, ctype string
		body        []byte
		path        string
		status      int
		code        string
	}{
		{"wrong type", "text/plain", png, path, 415, CodeUnsupportedMediaType},
		{"mismatched bytes", "image/jpeg", png, path, 400, CodeInvalidImage},
		{"empty", "image/png", nil, path, 400, CodeInvalidImage},
		{"too large", "image/png", append(slices.Clone(png), make([]byte, MaxAttachment)...), path, 413, CodeImageTooLarge},
		{"cannot attach", "image/png", png, api + "/conversations/c2/attachments", 409, CodeAttachmentUnsupported},
	}
	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			r := e.do("POST", tt.path, tt.body, "Content-Type", tt.ctype)
			if r.status != tt.status || r.problem().Code != tt.code {
				t.Fatalf("got %d %s", r.status, r.body)
			}
		})
	}
	var seenPath string
	inner := e.emacs.attach
	e.emacs.attach = func(p bridge.AttachParams) (bridge.AttachResult, error) {
		seenPath = p.Path
		return inner(p)
	}
	r := e.do("POST", path, png, "Content-Type", "image/png", "Idempotency-Key", "up-1")
	if r.status != 200 || !strings.HasPrefix(string(r.body), `{"text":"@phone-`) {
		t.Fatalf("attach %d %s", r.status, r.body)
	}
	if _, err := os.Stat(seenPath); !os.IsNotExist(err) {
		t.Fatalf("upload not deleted: %v", err)
	}
}

func TestImagesDiffsCommands(t *testing.T) {
	e := setup(t)
	root := t.TempDir()
	_ = os.WriteFile(root+"/shot.png", png, 0o600)
	e.st.SetConversation(bridge.ConversationSetParams{Conversation: bridge.Conversation{ID: "c3", Provider: "p", Status: "idle", Root: root, Controls: bridge.Controls{Actions: []string{"close"}}}})
	e.st.Event(bridge.Event{Conversation: "c3", At: time.Now(), Type: bridge.EventText, Text: "see shot.png"})
	snap, _ := e.st.Snapshot("c3")
	img := snap.Items[0].Images[0]
	r := e.do("GET", api+"/images/"+img, nil)
	if r.status != 200 || !bytes.Equal(r.body, png) || r.header.Get("Cache-Control") != "private, max-age=31536000, immutable" || r.header.Get("Content-Type") != "image/png" {
		t.Fatalf("image %d %v", r.status, r.header)
	}
	if r := e.do("GET", api+"/images/"+img, nil, "If-None-Match", `"`+img+`"`); r.status != 304 {
		t.Fatalf("image revalidation %d", r.status)
	}

	d := e.st.Dashboard("")
	project, plain := d.Sections[0].Node, d.Sections[0].Node.Children[0].Node
	if r := e.do("GET", api+"/nodes/"+project.ID+"/diff", nil); r.status != 200 || string(r.body) != `{"diff":"--- a\n+++ a\n"}` {
		t.Fatalf("diff %d %s", r.status, r.body)
	}
	if r := e.do("GET", api+"/nodes/"+plain.ID+"/diff", nil); r.status != 404 || r.problem().Code != CodeDiffMissing {
		t.Fatalf("no diff %d %s", r.status, r.body)
	}

	cmd := func(name, body string) result { return e.do("POST", api+"/nodes/"+project.ID+"/commands/"+name, body) }
	for _, tt := range []struct {
		name, body string
		status     int
		code       string
	}{
		{"nope", `{}`, 404, CodeCommandMissing},
		{"prompt", `{"text":" "}`, 400, CodeEmptyText},
		{"switch", `{"option":"c"}`, 400, CodeInvalidOption},
	} {
		if r := cmd(tt.name, tt.body); r.status != tt.status || r.problem().Code != tt.code {
			t.Errorf("%s: %d %s", tt.name, r.status, r.body)
		}
	}
	if r := e.do("POST", api+"/nodes/0123456789abcdef/commands/kill", `{}`); r.status != 404 || r.problem().Code != CodeNodeMissing {
		t.Errorf("missing node %d %s", r.status, r.body)
	}
	if r := cmd("prompt", `{"text":"go"}`); string(r.body) != `{"outcome":"done","draft":"go"}` {
		t.Fatalf("prompt command %s", r.body)
	}
	var res CommandResult
	_ = json.Unmarshal(cmd("kill", `{}`).body, &res)
	if res.Outcome != bridge.OutcomeConfirm || res.ConfirmationToken == "" {
		t.Fatalf("kill %+v", res)
	}
	body, _ := json.Marshal(map[string]any{"confirmations": res.Confirmations, "confirmationToken": res.ConfirmationToken})
	if r := cmd("kill", string(body)); string(r.body) != `{"outcome":"done"}` {
		t.Fatalf("confirmed kill %s", r.body)
	}
	last := e.emacs.cmds[len(e.emacs.cmds)-1]
	if !slices.Equal(last.Path, []string{"p"}) || !slices.Equal(last.Confirmed, []string{"Kill?"}) {
		t.Fatalf("forwarded %+v", last)
	}
}

func TestReceiptsBounds(t *testing.T) {
	r := &Receipts{}
	now := time.Now()
	r.now = func() time.Time { return now }
	ok := func(context.Context) Outcome { return Outcome{Status: 200, Body: []byte("{}"), Keep: true} }
	for i := range ReceiptLimit + 10 {
		r.Do(context.Background(), "k"+string(rune('a'+i%26))+strings.Repeat("x", i), "s", ok)
	}
	r.Do(context.Background(), "trigger", "s", ok)
	if n := r.Len(); n > ReceiptLimit+1 {
		t.Fatalf("receipts grew to %d", n)
	}
	now = now.Add(ReceiptTTL + time.Second)
	r.Do(context.Background(), "fresh", "s", ok)
	if n := r.Len(); n != 1 {
		t.Fatalf("expired receipts kept: %d", n)
	}
	r.Clear()
	if r.Len() != 0 {
		t.Fatal("Clear kept receipts")
	}
	calls := 0
	confirm := func(context.Context) Outcome { calls++; return Outcome{Status: 200, Body: []byte("{}")} }
	r.Do(context.Background(), "c", "s", confirm)
	r.Do(context.Background(), "c", "s", confirm)
	if calls != 2 {
		t.Fatal("unkept outcome was replayed")
	}
}

func TestReceiptsAndSecretSurviveRestart(t *testing.T) {
	r := &Receipts{}
	calls := 0
	write := func(context.Context) Outcome {
		calls++
		return Outcome{Status: 200, Body: []byte(`{"delivery":"sent"}`), Keep: true}
	}
	r.Do(context.Background(), "k1", "s", write)
	v := r.Version()
	data, _ := json.Marshal(r.Save())
	var saved []SavedReceipt
	if err := json.Unmarshal(data, &saved); err != nil {
		t.Fatal(err)
	}
	fresh := &Receipts{}
	fresh.Restore(saved)
	if o := fresh.Do(context.Background(), "k1", "s", write); calls != 1 || string(o.Body) != `{"delivery":"sent"}` {
		t.Fatalf("restored receipt not replayed: calls %d, %s", calls, o.Body)
	}
	if o := fresh.Do(context.Background(), "k1", "other", write); o.Status != http.StatusConflict {
		t.Fatalf("restored receipt lost its signature: %d", o.Status)
	}
	if r.Do(context.Background(), "k2", "s", write); r.Version() == v {
		t.Error("a kept outcome did not bump the version")
	}

	c := NewConfirmer()
	token := c.Token("node", "kill", "", "state", []string{"Kill?"})
	if !ConfirmerWithSecret(c.Secret()).Valid(token, "node", "kill", "", "state", []string{"Kill?"}) {
		t.Fatal("token from before the restart rejected")
	}
}

func TestFileLinks(t *testing.T) {
	e := setup(t)
	root := t.TempDir()
	_ = os.MkdirAll(root+"/docs", 0o700)
	_ = os.WriteFile(root+"/docs/报告 v1.pdf", []byte("pdf-bytes"), 0o600)
	_ = os.WriteFile(root+"/notes.txt", []byte("0123456789"), 0o600)
	_ = os.WriteFile(root+"/secret.txt", []byte("no"), 0o600)
	e.st.SetConversation(bridge.ConversationSetParams{Conversation: bridge.Conversation{ID: "c3", Provider: "p", Status: "idle", Root: root, Controls: bridge.Controls{Actions: []string{"close"}}}})
	e.st.Event(bridge.Event{Conversation: "c3", At: time.Now(), Type: bridge.EventText,
		Text: "See [the report](<docs/报告 v1.pdf>), [notes](" + root + "/notes.txt#L2), [line](notes.txt:3) and [dir](docs)."})

	link := func(path string) (FileLink, result) {
		r := e.do("POST", api+"/conversations/c3/files", map[string]string{"path": path})
		var l FileLink
		_ = json.Unmarshal(r.body, &l)
		return l, r
	}
	l, r := link("docs/%E6%8A%A5%E5%91%8A%20v1.pdf")
	if r.status != 200 || l.Name != "报告 v1.pdf" || l.Size != 9 || !strings.HasPrefix(l.URL, "/overlook/files/") {
		t.Fatalf("encoded link %d %s", r.status, r.body)
	}
	d := e.do("GET", l.URL, nil, "Authorization", "")
	if d.status != 200 || string(d.body) != "pdf-bytes" || !strings.HasPrefix(d.header.Get("Content-Disposition"), "attachment; filename*=utf-8''") {
		t.Fatalf("download %d %v %s", d.status, d.header, d.body)
	}
	if l, r := link(root + "/notes.txt"); r.status != 200 || l.Size != 10 {
		t.Fatalf("absolute %d %s", r.status, r.body)
	}
	if l, r := link("notes.txt:3"); r.status != 200 || l.Name != "notes.txt" {
		t.Fatalf("line suffix %d %s", r.status, r.body)
	}
	if l, r := link("file://" + root + "/notes.txt"); r.status != 404 {
		t.Fatalf("file URL not in text %d %+v", r.status, l)
	}
	for _, path := range []string{"secret.txt", root + "/secret.txt", "docs", "missing.txt"} {
		if _, r := link(path); r.status != 404 || r.problem().Code != CodeFileMissing {
			t.Errorf("%s: %d %s", path, r.status, r.body)
		}
	}
	if _, r := link(" "); r.status != 400 {
		t.Errorf("empty path %d", r.status)
	}
	if r := e.do("POST", api+"/conversations/zz/files", map[string]string{"path": "x"}); r.status != 404 || r.problem().Code != CodeConversationMissing {
		t.Errorf("missing conversation %d %s", r.status, r.body)
	}
	if d := e.do("GET", "/overlook/files/0123/x", nil, "Authorization", ""); d.status != 404 {
		t.Errorf("unknown ticket %d", d.status)
	}
}

func TestFileTicketsExpire(t *testing.T) {
	tk := newFileTickets()
	now := time.Now()
	tk.now = func() time.Time { return now }
	id := tk.issue("/x")
	if p, ok := tk.path(id); !ok || p != "/x" {
		t.Fatal("fresh ticket")
	}
	now = now.Add(FileTicketTTL)
	if _, ok := tk.path(id); ok {
		t.Fatal("expired ticket served")
	}
	tk.issue("/y")
	if len(tk.entries) != 1 {
		t.Fatalf("expired ticket kept: %d", len(tk.entries))
	}
}
