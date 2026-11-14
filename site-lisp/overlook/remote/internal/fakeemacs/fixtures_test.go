package fakeemacs

import (
	"bytes"
	"encoding/base64"
	"encoding/json"
	"fmt"
	"os"
	"testing"

	"github.com/guiyuanju/overlook/remote/internal/bridge"
	"github.com/guiyuanju/overlook/remote/internal/store"
)

const fixtureDir = "../../testdata/fixtures"

func strictParams(t *testing.T, where string, m bridge.Message) any {
	t.Helper()
	if m.JSONRPC != "2.0" {
		t.Fatalf("%s: jsonrpc = %q", where, m.JSONRPC)
	}
	p := bridge.NewParams(m.Method)
	if p == nil {
		t.Fatalf("%s: unknown method %q", where, m.Method)
	}
	if err := strictUnmarshal(m.Params, p); err != nil {
		t.Fatalf("%s: %s params: %v", where, m.Method, err)
	}
	return p
}

func TestFixturesMatchProtocol(t *testing.T) {
	f, err := Load(fixtureDir)
	if err != nil {
		t.Fatal(err)
	}
	hello := strictParams(t, "hello.json", f.Hello).(*bridge.HelloParams)
	if hello.Protocol != bridge.ProtocolVersion || len(f.Hello.ID) == 0 {
		t.Fatalf("hello = %+v", hello)
	}
	sync := strictParams(t, "sync.json", f.Sync).(*bridge.SyncParams)
	conversations := map[string]bridge.Conversation{}
	for _, c := range sync.Conversations {
		conversations[c.ID] = c
		if c.Root == "" || len(c.Controls.Actions) == 0 {
			t.Errorf("conversation %s lacks root or actions", c.ID)
		}
	}
	checkNodes(t, sync.Dashboard, conversations)

	var images int
	check := func(where string, m bridge.Message) {
		p := strictParams(t, where, m)
		switch p := p.(type) {
		case *bridge.Event:
			if _, ok := conversations[p.Conversation]; !ok {
				t.Errorf("%s: event for unknown conversation %s", where, p.Conversation)
			}
			if p.At.IsZero() {
				t.Errorf("%s: event without at", where)
			}
			for _, img := range p.Images {
				data, err := base64.StdEncoding.DecodeString(img.Data)
				if err != nil || store.SniffImage(data) != img.MIME {
					t.Errorf("%s: image data does not match %s", where, img.MIME)
				}
				images++
			}
		case *bridge.ConversationSetParams:
			if _, ok := conversations[p.Conversation.ID]; !ok {
				t.Errorf("%s: set for unknown conversation", where)
			}
		case *bridge.DashboardSetParams:
			checkNodes(t, p.Sections, conversations)
		}
	}
	for i, m := range f.Events {
		check(fmt.Sprintf("events.ndjson line %d", i+1), m)
	}
	for _, s := range f.Live {
		check("live.ndjson", s.Message)
	}
	if images == 0 {
		t.Error("no data images in fixtures")
	}

	for method, rs := range f.Responses {
		if bridge.NewParams(method) == nil {
			t.Errorf("responses.json: unknown method %s", method)
		}
		for _, r := range rs {
			if (r.Result == nil) == (r.Error == nil) {
				t.Errorf("responses.json %s: need exactly one of result and error", method)
				continue
			}
			if r.Error != nil {
				if r.Error.Problem() == "" {
					t.Errorf("responses.json %s: error without problem", method)
				}
				continue
			}
			if err := strictUnmarshal(r.Result, bridge.NewResult(method)); err != nil {
				t.Errorf("responses.json %s result: %v", method, err)
			}
		}
		if last := rs[len(rs)-1]; len(last.Match) != 0 {
			t.Errorf("responses.json %s: last response must be a catch-all", method)
		}
	}

	shot, err := os.ReadFile(f.Dir + "/root/alpha/screenshots/after.png")
	if err != nil || store.SniffImage(shot) != "image/png" {
		t.Fatalf("screenshot fixture: %v", err)
	}
}

func checkNodes(t *testing.T, nodes []bridge.Node, conversations map[string]bridge.Conversation) {
	t.Helper()
	keys := map[string]bool{}
	for _, n := range nodes {
		if n.Key == "" || n.Kind == "" || keys[n.Key] {
			t.Errorf("node %q: missing kind or key, or duplicate key", n.Title)
		}
		keys[n.Key] = true
		if n.Conversation != "" {
			if _, ok := conversations[n.Conversation]; !ok {
				t.Errorf("node %q: unknown conversation", n.Title)
			}
		}
		checkNodes(t, n.Children, conversations)
	}
}

func TestRespondMatchesFirstFit(t *testing.T) {
	f, err := Load(fixtureDir)
	if err != nil {
		t.Fatal(err)
	}
	params := func(v any) json.RawMessage { b, _ := json.Marshal(v); return b }
	first, _ := f.Respond(bridge.MethodAction, params(bridge.ActionParams{Conversation: "c", Action: "close"}))
	again, _ := f.Respond(bridge.MethodAction, params(bridge.ActionParams{Conversation: "c", Action: "close", Confirmed: []string{"q"}}))
	if !bytes.Contains(first.Result, []byte(`"confirm"`)) || !bytes.Contains(again.Result, []byte(`"closed"`)) {
		t.Fatalf("close flow: %s then %s", first.Result, again.Result)
	}
}
