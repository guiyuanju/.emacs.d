package main

import (
	"bufio"
	"encoding/json"
	"net/http"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"

	"github.com/guiyuanju/overlook/remote/internal/store"
)

// openStream reads the event stream at query until the test ends.
func (r *running) openStream(query string) <-chan sse {
	r.t.Helper()
	req, _ := http.NewRequest("GET", r.base+"/overlook/api/stream?"+query, nil)
	req.Header.Set("Authorization", "Bearer "+token)
	resp, err := http.DefaultClient.Do(req)
	if err != nil {
		r.t.Fatal(err)
	}
	r.t.Cleanup(func() { resp.Body.Close() })
	events := make(chan sse, 256)
	go func() {
		defer close(events)
		br := bufio.NewReader(resp.Body)
		var ev sse
		for {
			line, err := br.ReadString('\n')
			if err != nil {
				return
			}
			line = strings.TrimSuffix(line, "\n")
			switch {
			case line == "" && ev.event != "":
				events <- ev
				ev = sse{}
			case strings.HasPrefix(line, "id: "):
				ev.id = line[4:]
			case strings.HasPrefix(line, "event: "):
				ev.event = line[7:]
			case strings.HasPrefix(line, "data: "):
				ev.data = []byte(line[6:])
			}
		}
	}()
	return events
}

func (r *running) write(method, path, key, body string) (int, string) {
	r.t.Helper()
	req, _ := http.NewRequest(method, r.base+path, strings.NewReader(body))
	req.Header.Set("Authorization", "Bearer "+token)
	req.Header.Set("Idempotency-Key", key)
	resp, err := http.DefaultClient.Do(req)
	if err != nil {
		r.t.Fatal(err)
	}
	defer resp.Body.Close()
	var b strings.Builder
	_, _ = bufio.NewReader(resp.Body).WriteTo(&b)
	return resp.StatusCode, b.String()
}

// playUntilEnd plays the live steps, which must arrive as deltas, and returns the last cursor and the highest item id.
func playUntilEnd(t *testing.T, r *running, events <-chan sse) (lastID string, maxItem int64) {
	t.Helper()
	r.d.fake.PlayLive()
	deadline := time.After(10 * time.Second)
	for {
		var ev sse
		select {
		case ev = <-events:
		case <-deadline:
			t.Fatal("live replay incomplete")
		}
		if ev.id != "" {
			lastID = ev.id
		}
		if ev.event != "conversation" {
			continue
		}
		if strings.Contains(string(ev.data), `"reset":true`) {
			t.Fatalf("reset during live replay: %.200s", ev.data)
		}
		var d store.ConversationDelta
		if err := json.Unmarshal(ev.data, &d); err != nil {
			t.Fatal(err)
		}
		for _, it := range d.Items {
			maxItem = max(maxItem, it.Item)
			if it.Type == "tool" && it.Status == "completed" && it.Title == "Run go vet ./..." {
				return lastID, maxItem
			}
		}
	}
}

// TestRestartResumes restarts the daemon under a page's cursors: the page keeps streaming deltas without a reset.
func TestRestartResumes(t *testing.T) {
	cfg := baseConfig(t)
	cfg.StateFile = filepath.Join(filepath.Dir(cfg.TokenFile), "state", "state.json")
	r := launch(t, cfg)
	r.waitOnline()
	var dash store.Dashboard
	_ = json.Unmarshal(r.get("/overlook/api/dashboard").body, &dash)
	var snap store.ConversationSnapshot
	_ = json.Unmarshal(r.get("/overlook/api/conversations/"+conv).body, &snap)
	events := r.openStream("dashboard=" + dash.Known + "&conversation=" + conv + "&after=" + itoa(snap.Seq) + "&known=" + snap.Known + "&epoch=" + snap.Epoch)
	if ev := <-events; ev.event != "hello" {
		t.Fatalf("first event %s", ev.event)
	}
	lastID, maxItem := playUntilEnd(t, r, events)
	status, prompt := r.write("POST", "/overlook/api/conversations/"+conv+"/prompts", "restart-1", `{"text":"before"}`)
	if status != 200 {
		t.Fatalf("prompt %d %s", status, prompt)
	}
	var cursor struct{ Seq int64 }
	_ = json.Unmarshal(r.get("/overlook/api/conversations/"+conv).body, &cursor)
	if status, body := r.write("PUT", "/overlook/api/conversations/"+conv+"/read", "",
		`{"through":`+itoa(cursor.Seq)+`,"epoch":"`+snap.Epoch+`"}`); status != 200 {
		t.Fatalf("read %d %s", status, body)
	}
	r.stop()
	if fi, err := os.Stat(cfg.StateFile); err != nil || fi.Mode().Perm() != 0o600 {
		t.Fatalf("state file: %v %v", fi, err)
	}

	cfg.FakeResume = true
	r2 := launch(t, cfg)
	r2.waitOnline()
	events = r2.openStream(lastID)
	hello := <-events
	if hello.event != "hello" || !strings.Contains(string(hello.data), `"epoch":"`+snap.Epoch+`"`) {
		t.Fatalf("hello after restart %s %s", hello.event, hello.data)
	}
	quiet := time.After(500 * time.Millisecond)
	for done := false; !done; {
		select {
		case ev := <-events:
			if strings.Contains(string(ev.data), `"reset":true`) {
				t.Fatalf("reset after restart: %.200s", ev.data)
			}
			if ev.event == "dashboard" && !strings.Contains(string(ev.data), `"same"`) {
				t.Fatalf("full dashboard after restart: %.200s", ev.data)
			}
			if ev.event == "conversation" {
				var d store.ConversationDelta
				_ = json.Unmarshal(ev.data, &d)
				for _, it := range d.Items {
					if it.Item <= maxItem && it.Type != "prompt" {
						t.Fatalf("item %d resent after restart", it.Item)
					}
				}
			}
		case <-quiet:
			done = true
		}
	}
	var after store.ConversationSnapshot
	_ = json.Unmarshal(r2.get("/overlook/api/conversations/"+conv).body, &after)
	if after.Epoch != snap.Epoch || after.Conversation.ReadThrough != cursor.Seq || after.Conversation.UnreadCount != 0 {
		t.Fatalf("restored epoch %s readThrough %d unread %d", after.Epoch, after.Conversation.ReadThrough, after.Conversation.UnreadCount)
	}
	if status, again := r2.write("POST", "/overlook/api/conversations/"+conv+"/prompts", "restart-1", `{"text":"before"}`); status != 200 || again != prompt {
		t.Fatalf("idempotent replay after restart: %d %s, want %s", status, again, prompt)
	}
	// New items continue the numbering of the restored history.
	if _, newMax := playUntilEnd(t, r2, events); newMax <= maxItem {
		t.Fatalf("no new items after the restart: %d <= %d", newMax, maxItem)
	}
}

// TestUnreadableStateIsIgnored starts fresh from a corrupt state file.
func TestUnreadableStateIsIgnored(t *testing.T) {
	cfg := baseConfig(t)
	cfg.FakeEmacs = ""
	cfg.StateFile = filepath.Join(filepath.Dir(cfg.TokenFile), "state.json")
	if err := os.WriteFile(cfg.StateFile, []byte(`{"format":1,"store":`), 0o600); err != nil {
		t.Fatal(err)
	}
	r := launch(t, cfg)
	if res := r.get("/overlook/healthz"); res.status != 200 {
		t.Fatalf("healthz %d", res.status)
	}
	r.stop()
	if _, err := os.Stat(cfg.StateFile); err != nil {
		t.Fatal(err)
	}
	data, _ := os.ReadFile(cfg.StateFile)
	if !json.Valid(data) {
		t.Fatal("state file not rewritten on shutdown")
	}
}

// TestPeriodicSave writes changed state while running, so a crash loses little.
func TestPeriodicSave(t *testing.T) {
	old := saveInterval
	saveInterval = 50 * time.Millisecond
	t.Cleanup(func() { saveInterval = old })
	cfg := baseConfig(t)
	cfg.StateFile = filepath.Join(filepath.Dir(cfg.TokenFile), "state.json")
	r := launch(t, cfg)
	r.waitOnline()
	deadline := time.Now().Add(5 * time.Second)
	for {
		if data, err := os.ReadFile(cfg.StateFile); err == nil && strings.Contains(string(data), `"emacsEpoch":"48213-`) {
			break
		}
		if time.Now().After(deadline) {
			t.Fatal("state not saved while running")
		}
		time.Sleep(20 * time.Millisecond)
	}
	fi, _ := os.Stat(cfg.StateFile)
	time.Sleep(200 * time.Millisecond)
	if again, _ := os.Stat(cfg.StateFile); !again.ModTime().Equal(fi.ModTime()) {
		t.Error("unchanged state rewritten")
	}
}
