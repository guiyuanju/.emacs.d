package store

import (
	"encoding/base64"
	"encoding/json"
	"reflect"
	"testing"
	"time"

	"github.com/guiyuanju/overlook/remote/internal/bridge"
)

// TestSaveRestore checks that a restored store answers every cursor a page may hold exactly as before.
func TestSaveRestore(t *testing.T) {
	dir := t.TempDir()
	s := New(Options{Dir: dir, Now: func() time.Time { return t0 }})
	online(t, s, "e1", conversation("c1", ""), conversation("c2", ""))
	oldDash := s.DashboardKnown()
	s.Event(event("c1", bridge.EventPrompt, "go"))
	s.Event(event("c1", bridge.EventText, "Hel"))
	mid := s.Snapshot
	snapMid, _ := mid("c1")
	s.Event(event("c1", bridge.EventText, "lo wörld"))
	s.Event(bridge.Event{Conversation: "c1", At: t0, Type: bridge.EventTool, ID: "t1", Title: "Edit", Status: "completed",
		Diffs: []bridge.Diff{{File: "a", Old: "x\n", New: "y\n"}}})
	s.Event(bridge.Event{Conversation: "c2", At: t0, Type: bridge.EventText, Text: "img",
		Images: []bridge.Image{{Data: base64.StdEncoding.EncodeToString(png), MIME: "image/png"}}})
	if _, _, err := s.Read("c1", snapMid.Seq, s.Epoch()); err != nil {
		t.Fatal(err)
	}
	nodes := tree()
	nodes[1].Title = "changed"
	s.SetDashboard(bridge.DashboardSetParams{Sections: nodes})
	s.Disconnected()

	data, err := json.Marshal(s.Save())
	if err != nil {
		t.Fatal(err)
	}
	var saved Saved
	if err := json.Unmarshal(data, &saved); err != nil {
		t.Fatal(err)
	}
	r := New(Options{Dir: dir, Now: func() time.Time { return t0.Add(time.Hour) }})
	r.Restore(&saved)

	same := func(what string, a, b any) {
		t.Helper()
		if !reflect.DeepEqual(a, b) {
			ja, _ := json.Marshal(a)
			jb, _ := json.Marshal(b)
			t.Errorf("%s differs after restore:\n%s\n%s", what, ja, jb)
		}
	}
	same("epoch", s.Epoch(), r.Epoch())
	same("dashboard", s.Dashboard(""), r.Dashboard(""))
	same("dashboard delta", s.Dashboard(oldDash), r.Dashboard(oldDash))
	if _, ok := r.DashboardDelta(s.DashboardKnown()); ok {
		t.Error("current dashboard cursor not current after restore")
	}
	same("conversations", s.Conversations(), r.Conversations())
	for _, id := range []string{"c1", "c2"} {
		a, _ := s.Snapshot(id)
		b, _ := r.Snapshot(id)
		same("snapshot "+id, a, b)
		da, ra, oka, _ := s.Delta(id, snapMid.Epoch, snapMid.Seq, snapMid.Known)
		db, rb, okb, _ := r.Delta(id, snapMid.Epoch, snapMid.Seq, snapMid.Known)
		same("delta "+id, []any{da, ra, oka}, []any{db, rb, okb})
		if ra {
			t.Errorf("%s: a cursor from before the restart resets", id)
		}
		if _, _, ok, _ := r.Delta(id, b.Epoch, b.Seq, b.Known); ok {
			t.Errorf("%s: an up-to-date cursor gets a delta", id)
		}
	}
	snap, _ := r.Snapshot("c2")
	if img, err := r.Image(snap.Items[0].Images[0]); err != nil || img.MIME != "image/png" {
		t.Errorf("image index lost: %v", err)
	}

	// The same Emacs epoch keeps everything; the item numbering continues.
	r.Connected(bridge.HelloParams{Protocol: 1, Epoch: "e1"})
	if r.Epoch() != s.Epoch() {
		t.Fatal("same Emacs epoch started a new history epoch")
	}
	r.Event(event("c1", bridge.EventText, "!"))
	if d, reset, _, _ := r.Delta("c1", snapMid.Epoch, snapMid.Seq, snapMid.Known); reset || d.Seq != saved.Seq+1 {
		t.Errorf("after restore: reset %v seq %d", reset, d.Seq)
	}
	// Another Emacs epoch discards it.
	r.Connected(bridge.HelloParams{Protocol: 1, Epoch: "e2"})
	if r.Epoch() == s.Epoch() {
		t.Fatal("new Emacs epoch kept the history epoch")
	}
	if snap, _ := r.Snapshot("c1"); len(snap.Items) != 0 {
		t.Errorf("new Emacs epoch kept %d items", len(snap.Items))
	}
}

func TestVersionCounts(t *testing.T) {
	s, _ := newStore(t)
	v := s.Version()
	s.Event(event("c9", bridge.EventText, "x"))
	if s.Version() == v {
		t.Fatal("an event did not bump the version")
	}
}
