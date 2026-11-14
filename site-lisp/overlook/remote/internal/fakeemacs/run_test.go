package fakeemacs

import (
	"context"
	"os"
	"path/filepath"
	"testing"
	"time"

	"github.com/guiyuanju/overlook/remote/internal/bridge"
	"github.com/guiyuanju/overlook/remote/internal/store"
)

func TestRunAgainstBridge(t *testing.T) {
	dir, err := os.MkdirTemp("", "ovf")
	if err != nil {
		t.Fatal(err)
	}
	defer os.RemoveAll(dir)
	socket := filepath.Join(dir, "bridge.sock")
	st := store.New(store.Options{Dir: dir})
	srv := bridge.NewServer(socket, "test", st, nil)
	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()
	go func() { _ = srv.Serve(ctx) }()

	fx, err := Load(fixtureDir)
	if err != nil {
		t.Fatal(err)
	}
	calls := make(chan bridge.Message, 8)
	f := &Fake{Socket: socket, Fixtures: fx, Calls: calls, Speed: 50, LiveDelay: 0}
	done := make(chan error, 1)
	go func() { done <- f.Run(ctx) }()

	conv := "conversation-06f8144e9a2601385f737f5cb6540bf9f5df039c802afaa355a3296461e4b160"
	deadline := time.Now().Add(5 * time.Second)
	for {
		snap, err := st.Snapshot(conv)
		if err == nil && len(snap.Items) > 0 && snap.Items[len(snap.Items)-1].Title == "Run go vet ./..." && snap.Items[len(snap.Items)-1].Status == "completed" {
			break
		}
		if time.Now().After(deadline) {
			t.Fatalf("live steps not applied: %+v %v", snap.Items, err)
		}
		time.Sleep(10 * time.Millisecond)
	}
	res, err := srv.Action(ctx, bridge.ActionParams{Conversation: conv, Action: "close"})
	if err != nil || res.Outcome != bridge.OutcomeConfirm {
		t.Fatalf("canned action %+v %v", res, err)
	}
	if m := <-calls; m.Method != bridge.MethodAction {
		t.Fatalf("calls got %+v", m)
	}
	if err := srv.Ping(ctx); err != nil {
		t.Fatal(err)
	}
	<-calls
	_, err = srv.Earlier(ctx, bridge.ConversationParams{Conversation: conv})
	if err != nil {
		t.Fatalf("earlier %v", err)
	}
	<-calls
	if _, err := srv.Diff(ctx, bridge.DiffParams{Path: []string{"x"}}); err != nil {
		t.Fatalf("diff %v", err)
	}
	<-calls
	cancel()
	if err := <-done; err != nil {
		t.Fatal(err)
	}
}

func TestAnswersRequestsWhileReplaying(t *testing.T) {
	// Short, as unix socket paths are limited to about 100 bytes.
	dir, err := os.MkdirTemp("", "ovf")
	if err != nil {
		t.Fatal(err)
	}
	defer os.RemoveAll(dir)
	socket := filepath.Join(dir, "bridge.sock")
	st := store.New(store.Options{Dir: dir})
	srv := bridge.NewServer(socket, "test", st, nil)
	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()
	go func() { _ = srv.Serve(ctx) }()
	fx, err := Load(fixtureDir)
	if err != nil {
		t.Fatal(err)
	}
	f := &Fake{Socket: socket, Fixtures: fx, Speed: 1, LiveDelay: 0}
	done := make(chan error, 1)
	go func() { done <- f.Run(ctx) }()

	conv := "conversation-06f8144e9a2601385f737f5cb6540bf9f5df039c802afaa355a3296461e4b160"
	finished := func() bool {
		snap, err := st.Snapshot(conv)
		last := len(snap.Items) - 1
		return err == nil && last >= 0 && snap.Items[last].Title == "Run go vet ./..." && snap.Items[last].Status == "completed"
	}
	for st.Emacs() != store.EmacsOnline {
		time.Sleep(time.Millisecond)
	}
	for range 3 {
		start := time.Now()
		if err := srv.Ping(ctx); err != nil {
			t.Fatal(err)
		}
		res, err := srv.Action(ctx, bridge.ActionParams{Conversation: conv, Action: "close"})
		if err != nil || res.Outcome != bridge.OutcomeConfirm {
			t.Fatalf("action %+v %v", res, err)
		}
		if waited := time.Since(start); waited > 500*time.Millisecond {
			t.Fatalf("requests waited %v for the replay", waited)
		}
		if finished() {
			t.Fatal("the live steps ended before the requests were answered")
		}
		time.Sleep(100 * time.Millisecond)
	}
	deadline := time.Now().Add(10 * time.Second)
	for !finished() {
		if time.Now().After(deadline) {
			t.Fatal("live steps did not finish after the requests")
		}
		time.Sleep(20 * time.Millisecond)
	}
	cancel()
	if err := <-done; err != nil {
		t.Fatal(err)
	}
}
