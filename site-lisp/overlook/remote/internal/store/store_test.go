package store

import (
	"encoding/base64"
	"encoding/json"
	"errors"
	"fmt"
	"os"
	"path/filepath"
	"slices"
	"strings"
	"sync"
	"testing"
	"time"

	"github.com/guiyuanju/overlook/remote/internal/bridge"
)

var t0 = time.Date(2026, 11, 13, 8, 0, 0, 0, time.UTC)

// png is a minimal PNG header, enough for magic-byte checks.
var png = []byte("\x89PNG\r\n\x1a\nrest-of-image")

type changes struct {
	mu  sync.Mutex
	all []Change
}

func (c *changes) add(ch Change) {
	c.mu.Lock()
	c.all = append(c.all, ch)
	c.mu.Unlock()
}

func (c *changes) last() Change {
	c.mu.Lock()
	defer c.mu.Unlock()
	if len(c.all) == 0 {
		return Change{}
	}
	return c.all[len(c.all)-1]
}

func newStore(t *testing.T) (*Store, *changes) {
	t.Helper()
	s := New(Options{Dir: t.TempDir(), Now: func() time.Time { return t0 }})
	ch := &changes{}
	s.OnChange(ch.add)
	return s, ch
}

func conversation(id, root string) bridge.Conversation {
	return bridge.Conversation{ID: id, Provider: "claude", Title: id, Status: bridge.StatusWorking, Root: root,
		Controls: bridge.Controls{Actions: []string{"close", "stop"}}}
}

func online(t *testing.T, s *Store, epoch string, convs ...bridge.Conversation) {
	t.Helper()
	s.Connected(bridge.HelloParams{Protocol: 1, Epoch: epoch})
	s.Sync(bridge.SyncParams{Dashboard: tree(), Conversations: convs})
}

func tree() []bridge.Node {
	return []bridge.Node{
		{Key: "projects", Kind: "group", Title: "Projects", Children: []bridge.Node{
			{Key: "p1", Kind: "project", Title: "overlook", Children: []bridge.Node{
				{Key: "a1", Kind: "agent", Title: "agent one", Conversation: "c1", Subtitle: "thinking",
					Commands: []bridge.Command{{Name: "kill", Label: "Kill", Confirm: true}}},
			}},
			{Key: "p2", Kind: "project", Title: "other"},
		}},
		{Key: "dup", Kind: "text", Title: "first"},
		{Key: "dup", Kind: "text", Title: "second"},
	}
}

func event(conv string, typ bridge.EventType, text string) bridge.Event {
	return bridge.Event{Conversation: conv, At: t0, Type: typ, Text: text}
}

func TestDashboardVersionsAndDeltas(t *testing.T) {
	s, ch := newStore(t)
	if d := s.Dashboard(""); d.Known != "" || len(d.Sections) != 0 || d.Emacs != EmacsOffline {
		t.Fatalf("empty dashboard %+v", d)
	}
	online(t, s, "e1", conversation("c1", ""))
	if !ch.last().Dashboard || s.Emacs() != EmacsOnline {
		t.Fatalf("sync change %+v", ch.last())
	}
	first := s.Dashboard("")
	if len(first.Sections) != 3 || first.Known == "" {
		t.Fatalf("sections %d", len(first.Sections))
	}
	if first.Sections[1].Node.ID == first.Sections[2].Node.ID {
		t.Fatal("duplicate sibling keys share an id")
	}
	if _, ok := s.DashboardDelta(first.Known); ok {
		t.Fatal("delta for the current version")
	}

	next := tree()
	next[0].Children[1].Title = "renamed"
	s.SetDashboard(bridge.DashboardSetParams{Sections: next})
	delta, ok := s.DashboardDelta(first.Known)
	if !ok {
		t.Fatal("no delta after change")
	}
	projects := delta.Sections[0].Node
	if projects == nil || projects.Children[0].Same == "" || projects.Children[1].Node.Title != "renamed" ||
		delta.Sections[1].Same == "" || delta.Sections[2].Same == "" {
		data, _ := json.Marshal(delta)
		t.Fatalf("delta %s", data)
	}
	if full := s.Dashboard("unknown"); full.Sections[1].Node == nil {
		t.Fatal("unknown cursor did not get full nodes")
	}

	before := len(ch.all)
	s.SetDashboard(bridge.DashboardSetParams{Sections: next})
	if len(ch.all) != before {
		t.Fatal("identical dashboard produced a change")
	}

	for i := range DashboardVersions + 5 {
		n := tree()
		n[1].Title = fmt.Sprint("v", i)
		s.SetDashboard(bridge.DashboardSetParams{Sections: n})
	}
	if len(s.versions) != DashboardVersions {
		t.Fatalf("versions kept %d", len(s.versions))
	}
	if d := s.Dashboard(first.Known); d.Sections[0].Node == nil || d.Sections[0].Same != "" {
		t.Fatal("expired cursor got a delta")
	}
}

func TestNodeTargetAndConfirmState(t *testing.T) {
	s, _ := newStore(t)
	online(t, s, "e1", conversation("c1", ""))
	d := s.Dashboard("")
	agent := d.Sections[0].Node.Children[0].Node.Children[0].Node
	path, node, err := s.NodeTarget(agent.ID)
	if err != nil || !slices.Equal(path, []string{"projects", "p1", "a1"}) || node.Commands[0].Name != "kill" {
		t.Fatalf("target %v %+v %v", path, node, err)
	}
	dup, _, _ := s.NodeTarget(d.Sections[2].Node.ID)
	if !slices.Equal(dup, []string{"dup#2"}) {
		t.Fatalf("duplicate path %v", dup)
	}
	state, _ := s.NodeConfirmState(agent.ID)
	n := tree()
	n[0].Children[0].Children[0].Subtitle = "still thinking"
	s.SetDashboard(bridge.DashboardSetParams{Sections: n})
	if again, _ := s.NodeConfirmState(agent.ID); again != state {
		t.Fatal("subtitle changed the confirmation state")
	}
	n[0].Children[0].Children[0].Title = "renamed"
	s.SetDashboard(bridge.DashboardSetParams{Sections: n})
	if again, _ := s.NodeConfirmState(agent.ID); again == state {
		t.Fatal("title change kept the confirmation state")
	}
	if _, _, err := s.NodeTarget("0000000000000000"); !errors.Is(err, ErrNodeMissing) {
		t.Fatal(err)
	}
}

func TestTextItemsUTF16(t *testing.T) {
	s, _ := newStore(t)
	online(t, s, "e1", conversation("c1", ""))
	s.Event(event("c1", bridge.EventPrompt, "hi"))
	s.Event(event("c1", bridge.EventText, "a😀"))
	snap, _ := s.Snapshot("c1")
	after := snap.Seq
	s.Event(event("c1", bridge.EventText, "é b"))
	d, reset, ok, err := s.Delta("c1", snap.Epoch, after, snap.Known)
	if err != nil || reset || !ok || len(d.Items) != 1 {
		t.Fatalf("delta %+v reset=%v ok=%v err=%v", d, reset, ok, err)
	}
	if it := d.Items[0]; it.Text != "é b" || it.Offset != 3 || it.Type != bridge.EventText {
		t.Fatalf("suffix item %+v", it)
	}
	if d.Conversation != nil {
		t.Fatalf("extending an unread item resent the unchanged conversation: %+v", d.Conversation)
	}
	s.Event(event("c1", bridge.EventEnd, ""))
	s.Event(event("c1", bridge.EventText, "new reply"))
	snap2, _ := s.Snapshot("c1")
	if n := len(snap2.Items); n != 4 || snap2.Items[3].Text != "new reply" || snap2.Items[1].Text != "a😀é b" {
		t.Fatalf("items %+v", snap2.Items)
	}
	if snap2.Conversation.UnreadCount != 2 {
		t.Fatalf("unread %d", snap2.Conversation.UnreadCount)
	}
}

func TestDeltaCases(t *testing.T) {
	s, _ := newStore(t)
	online(t, s, "e1", conversation("c1", ""))
	s.Event(event("c1", bridge.EventPrompt, "one"))
	snap, _ := s.Snapshot("c1")
	tests := []struct {
		name          string
		epoch         string
		after         int64
		known         string
		reset, ok     bool
		wantItems     int
		wantConvState bool
	}{
		{"unchanged", snap.Epoch, snap.Seq, snap.Known, false, false, 0, false},
		{"other epoch", "old", snap.Seq, snap.Known, true, true, 0, false},
		{"ahead", snap.Epoch, snap.Seq + 100, snap.Known, true, true, 0, false},
		{"stale state", snap.Epoch, snap.Seq, "nope", false, true, 0, true},
		{"from zero", snap.Epoch, 0, snap.Known, false, true, 1, false},
	}
	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			d, reset, ok, err := s.Delta("c1", tt.epoch, tt.after, tt.known)
			if err != nil || reset != tt.reset || ok != tt.ok || len(d.Items) != tt.wantItems || (d.Conversation != nil) != tt.wantConvState {
				t.Fatalf("got %+v reset=%v ok=%v err=%v", d, reset, ok, err)
			}
		})
	}
	if _, _, _, err := s.Delta("missing", snap.Epoch, 0, ""); !errors.Is(err, ErrConversationMissing) {
		t.Fatal(err)
	}
}

func TestToolMergeAndDiff(t *testing.T) {
	s, _ := newStore(t)
	online(t, s, "e1", conversation("c1", ""))
	diffs := []bridge.Diff{{File: "a.go", Old: "one\ntwo\n", New: "one\nthree\n"}}
	s.Event(bridge.Event{Conversation: "c1", At: t0, Type: bridge.EventTool, ID: "t1", Title: "Edit a.go", Status: "pending", Kind: "edit", Diffs: diffs})
	s.Event(bridge.Event{Conversation: "c1", At: t0.Add(time.Second), Type: bridge.EventTool, ID: "t1", Status: "completed"})
	snap, _ := s.Snapshot("c1")
	if len(snap.Items) != 1 {
		t.Fatalf("items %d", len(snap.Items))
	}
	it := snap.Items[0]
	want := "--- a.go\n+++ a.go\n@@ -1,2 +1,2 @@\n one\n-two\n+three\n"
	if it.Title != "Edit a.go" || it.Status != "completed" || it.Kind != "edit" || it.Diff != want || it.UpdatedAt != "2026-11-13T08:00:01.000Z" {
		t.Fatalf("tool item %+v\n%q", it, it.Diff)
	}
}

func TestUnifiedDiff(t *testing.T) {
	tests := []struct {
		name  string
		diffs []bridge.Diff
		want  string
	}{
		{"new file", []bridge.Diff{{File: "n", New: "a\nb"}}, "--- n\n+++ n\n@@ -0,0 +1,2 @@\n+a\n+b\n"},
		{"unchanged", []bridge.Diff{{File: "u", Old: "x\n", New: "x\n"}}, ""},
		{"two files", []bridge.Diff{{File: "a", Old: "1\n", New: "2\n"}, {Old: "", New: "z\n"}},
			"--- a\n+++ a\n@@ -1 +1 @@\n-1\n+2\n--- file\n+++ file\n@@ -0,0 +1 @@\n+z\n"},
	}
	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			if got := UnifiedDiff(tt.diffs); got != tt.want {
				t.Fatalf("got %q want %q", got, tt.want)
			}
		})
	}
	long := UnifiedDiff([]bridge.Diff{{File: "big", New: strings.Repeat("ä line\n", 5000)}})
	if !strings.HasSuffix(long, "\n…") || len([]rune(long)) != DiffChars+2 {
		t.Fatalf("cut diff has %d runes", len([]rune(long)))
	}
}

func TestRetentionAndHistory(t *testing.T) {
	s, _ := newStore(t)
	online(t, s, "e1", conversation("c1", ""))
	for i := range ItemsRetained + 20 {
		s.Event(event("c1", bridge.EventPrompt, fmt.Sprint("p", i)))
	}
	snap, _ := s.Snapshot("c1")
	if len(snap.Items) != PageSize || !snap.History.HasMore || snap.History.Before != snap.Items[0].Item {
		t.Fatalf("snapshot page %d %+v", len(snap.Items), snap.History)
	}
	page, err := s.History("c1", snap.History.Before, 100, snap.Epoch)
	if err != nil || len(page.Items) != 100 || !page.HasMore || page.Items[99].Item != snap.History.Before-1 {
		t.Fatalf("page %d %+v %v", len(page.Items), page.HasMore, err)
	}
	rest, err := s.History("c1", page.Before, 100, snap.Epoch)
	if err == nil {
		rest, err = s.History("c1", rest.Before, 100, snap.Epoch)
	}
	if err != nil || rest.HasMore || len(rest.Items) != ItemsRetained-PageSize-200 {
		t.Fatalf("rest %d %v %v", len(rest.Items), rest.HasMore, err)
	}
	if _, err := s.History("c1", rest.Items[0].Item, 10, snap.Epoch); !errors.Is(err, ErrHistoryExpired) {
		t.Fatalf("history before evicted items: %v", err)
	}
	if _, err := s.History("c1", 999, 10, "other"); !errors.Is(err, ErrHistoryExpired) {
		t.Fatal(err)
	}
	if _, reset, _, _ := s.Delta("c1", snap.Epoch, 3, ""); !reset {
		t.Fatal("cursor below the history floor did not reset")
	}
}

func TestReadPositions(t *testing.T) {
	s, ch := newStore(t)
	online(t, s, "e1", conversation("c1", ""))
	s.Event(event("c1", bridge.EventText, "one"))
	s.Event(event("c1", bridge.EventEnd, ""))
	s.Event(event("c1", bridge.EventText, "two"))
	snap, _ := s.Snapshot("c1")
	if snap.Conversation.UnreadCount != 2 || s.Dashboard("").Sections[0].Node.Children[0].Node.Children[0].Node.UnreadCount != 2 {
		t.Fatal("unread not overlaid")
	}
	tests := []struct {
		through     int64
		wantThrough int64
		wantUnread  int
		caughtUp    bool
	}{
		{1, 1, 1, false},
		{0, 1, 1, false},
		{1000, snap.Seq, 0, true},
	}
	for _, tt := range tests {
		r, caught, err := s.Read("c1", tt.through, snap.Epoch)
		if err != nil || r.ReadThrough != tt.wantThrough || r.UnreadCount != tt.wantUnread || caught != tt.caughtUp {
			t.Fatalf("Read(%d) = %+v %v %v", tt.through, r, caught, err)
		}
	}
	if !ch.last().Dashboard {
		t.Fatal("catching up did not change the dashboard")
	}
	if _, _, err := s.Read("c1", 1, "old"); !errors.Is(err, ErrHistoryExpired) {
		t.Fatal(err)
	}
	if _, _, err := s.Read("nope", 1, snap.Epoch); !errors.Is(err, ErrConversationMissing) {
		t.Fatal(err)
	}
}

func TestEpochs(t *testing.T) {
	s, ch := newStore(t)
	online(t, s, "e1", conversation("c1", ""), conversation("c2", ""))
	s.Event(event("c1", bridge.EventText, "kept"))
	epoch := s.Epoch()

	s.Disconnected()
	if s.Emacs() != EmacsOffline || !ch.last().Status {
		t.Fatal("not offline")
	}
	if _, err := s.Snapshot("c1"); err != nil {
		t.Fatal("snapshot lost while offline")
	}
	if got := s.Connected(bridge.HelloParams{Epoch: "e1", Lost: 2}); got != epoch {
		t.Fatalf("same Emacs epoch changed history epoch %s → %s", epoch, got)
	}
	s.Sync(bridge.SyncParams{Dashboard: tree(), Conversations: []bridge.Conversation{conversation("c1", "")}})
	if !slices.Equal(ch.last().Gone, []string{"c2"}) {
		t.Fatalf("gone %v", ch.last().Gone)
	}
	s.Event(event("c1", bridge.EventText, "after gap"))
	snap, _ := s.Snapshot("c1")
	if len(snap.Items) != 2 {
		t.Fatalf("lost events did not close the text item: %d items", len(snap.Items))
	}

	got := s.Connected(bridge.HelloParams{Epoch: "e2"})
	if got == epoch || !ch.last().Epoch {
		t.Fatal("new Emacs epoch kept the history epoch")
	}
	s.Sync(bridge.SyncParams{Conversations: []bridge.Conversation{conversation("c1", "")}})
	snap, _ = s.Snapshot("c1")
	if len(snap.Items) != 0 || snap.Seq != 0 || snap.Epoch != got {
		t.Fatalf("activity survived a new epoch: %+v", snap)
	}
}

func TestEventsBeforeConversationSet(t *testing.T) {
	s, _ := newStore(t)
	online(t, s, "e1")
	s.Event(event("new", bridge.EventPrompt, "early"))
	if _, err := s.Snapshot("new"); !errors.Is(err, ErrConversationMissing) {
		t.Fatal("hidden conversation visible")
	}
	if len(s.Conversations().Conversations) != 0 {
		t.Fatal("hidden conversation listed")
	}
	s.SetConversation(bridge.ConversationSetParams{Conversation: conversation("new", "")})
	snap, err := s.Snapshot("new")
	if err != nil || len(snap.Items) != 1 || snap.Items[0].Text != "early" {
		t.Fatalf("early event lost: %+v %v", snap, err)
	}
	s.RemoveConversation(bridge.ConversationParams{Conversation: "new"})
	if _, err := s.Snapshot("new"); !errors.Is(err, ErrConversationMissing) {
		t.Fatal("removed conversation remains")
	}
}

func TestImages(t *testing.T) {
	root := t.TempDir()
	if err := os.MkdirAll(filepath.Join(root, "shots"), 0o755); err != nil {
		t.Fatal(err)
	}
	_ = os.WriteFile(filepath.Join(root, "shots", "a.png"), png, 0o644)
	_ = os.WriteFile(filepath.Join(root, "fake.png"), []byte("not a png"), 0o644)
	s, _ := newStore(t)
	online(t, s, "e1", conversation("c1", root))
	s.Event(event("c1", bridge.EventPrompt, "see @shots/a.png and fake.png and missing.png"))
	s.Event(event("c1", bridge.EventText, "split shots/"))
	s.Event(event("c1", bridge.EventText, "a.png end"))
	data := base64.StdEncoding.EncodeToString(png)
	s.Event(bridge.Event{Conversation: "c1", At: t0, Type: bridge.EventTool, ID: "t", Output: "wrote " + root + "/shots/a.png",
		Images: []bridge.Image{{Data: data, MIME: "image/png"}, {Data: data, MIME: "image/gif"}}})
	snap, _ := s.Snapshot("c1")
	for i, it := range snap.Items {
		if len(it.Images) != 1 {
			t.Fatalf("item %d images %v", i, it.Images)
		}
	}
	img, err := s.Image(snap.Items[0].Images[0])
	if err != nil || img.MIME != "image/png" || img.Size != int64(len(png)) {
		t.Fatalf("image %+v %v", img, err)
	}
	f, err := img.Open()
	if err != nil {
		t.Fatal(err)
	}
	f.Close()
	if _, err := s.Image("0123456789abcdef"); !errors.Is(err, ErrImageMissing) {
		t.Fatal(err)
	}
}

func TestImageLRU(t *testing.T) {
	m := newMedia(t.TempDir(), 2, 1<<20)
	ids := []string{}
	for i := range 3 {
		id, err := m.add(append(slices.Clone(png), byte(i)), "image/png")
		if err != nil {
			t.Fatal(err)
		}
		ids = append(ids, id)
	}
	if _, ok := m.get(ids[0]); ok {
		t.Fatal("oldest image not evicted")
	}
	if _, ok := m.get(ids[2]); !ok {
		t.Fatal("newest image evicted")
	}
}

func TestImagePaths(t *testing.T) {
	home, _ := os.UserHomeDir()
	tests := []struct {
		text string
		want []string
	}{
		{"see @screenshots/after.png now", []string{"/r/screenshots/after.png"}},
		{`quoted @"dir with space/x.JPG" ok`, []string{"/r/dir with space/x.JPG"}},
		{"file:///tmp/a.webp, and /abs/b.gif;", []string{"/tmp/a.webp", "/abs/b.gif"}},
		{"~/pic.jpeg", []string{filepath.Join(home, "pic.jpeg")}},
		{"name.png.bak is fine but name.pngx is not", []string{"/r/name.png"}},
		{"under_score.png_ dash.png- 图片a.png图", nil},
		{"(paren/x.png) [y.png] <z.png>", []string{"/r/paren/x.png", "/r/y.png", "/r/z.png"}},
		{"percent%20name.png twice percent%20name.png", []string{"/r/percent name.png"}},
		{"no image here.txt", nil},
	}
	for _, tt := range tests {
		if got := ImagePaths(tt.text, "/r"); !slices.Equal(got, tt.want) {
			t.Errorf("ImagePaths(%q) = %q, want %q", tt.text, got, tt.want)
		}
	}
}

func TestSaveUpload(t *testing.T) {
	s, _ := newStore(t)
	path, name, err := s.SaveUpload(png, "image/png")
	if err != nil || name != "phone-20261113-080000-000.png" {
		t.Fatalf("%s %s %v", path, name, err)
	}
	fi, err := os.Stat(path)
	if err != nil || fi.Mode().Perm() != 0o600 {
		t.Fatalf("upload file %v %v", fi, err)
	}
}
