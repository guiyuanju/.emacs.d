package usage

import (
	"context"
	"database/sql"
	"fmt"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"
)

func claudeRecord(session string, output int) string {
	return fmt.Sprintf(`{"type":"assistant","timestamp":"2026-11-17T01:00:00Z","sessionId":%q,"cwd":"/work/alpha","message":{"id":"message","usage":{"output_tokens":%d}}}`+"\n", session, output)
}

func TestSourceRewriteDetection(t *testing.T) {
	for _, kind := range []string{"shrink-with-partial-tail", "replace-larger", "replace-same-size-and-time", "rewrite-in-place-larger"} {
		t.Run(kind, func(t *testing.T) {
			dir := t.TempDir()
			path := filepath.Join(dir, "a.jsonl")
			old := claudeRecord("old", 1)
			if kind == "shrink-with-partial-tail" {
				old += strings.Repeat("x", 4096)
			}
			appendLog(t, path, old)
			l := openTest(t, Options{Sources: []Source{{"claude", dir}}})
			l.Scan(context.Background())
			before, _ := os.Stat(path)
			replacement := claudeRecord("new", 2)
			if kind != "replace-same-size-and-time" {
				replacement += claudeRecord("third", 3)
			}
			if strings.Contains(kind, "larger") {
				replacement += `{"type":"ignored","padding":"` + strings.Repeat("x", 4096) + "\"}\n"
			}
			if kind == "replace-same-size-and-time" && len(replacement) != len(old) {
				t.Fatal("test needs equal lengths")
			}
			if strings.HasPrefix(kind, "replace-") {
				tmp := filepath.Join(dir, "swap")
				if err := os.WriteFile(tmp, []byte(replacement), 0600); err != nil {
					t.Fatal(err)
				}
				if err := os.Chtimes(tmp, before.ModTime(), before.ModTime()); err != nil {
					t.Fatal(err)
				}
				if err := os.Rename(tmp, path); err != nil {
					t.Fatal(err)
				}
			} else if err := os.WriteFile(path, []byte(replacement), 0600); err != nil {
				t.Fatal(err)
			}
			l.Scan(context.Background())
			want := int64(6)
			if kind == "replace-same-size-and-time" {
				want = 3
			}
			if got := total(l).Output; got != want {
				t.Fatalf("lost rewritten events: got %d want %d", got, want)
			}
			l.Scan(context.Background())
			if got := total(l).Output; got != want {
				t.Fatalf("replayed events: %d", got)
			}
		})
	}
}

func TestProjectResolutionSharedWithinScanAndRefreshedNextScan(t *testing.T) {
	dir := t.TempDir()
	for _, file := range []string{"a", "b"} {
		appendLog(t, filepath.Join(dir, file+".jsonl"), claudeRecord(file, 1))
	}
	calls, project := 0, "alpha"
	l := openTest(t, Options{Sources: []Source{{"claude", dir}}, Project: func(string) string { calls++; return project }})
	l.Scan(context.Background())
	if calls != 1 {
		t.Fatalf("resolved same root %d times", calls)
	}
	project = "renamed"
	appendLog(t, filepath.Join(dir, "a.jsonl"), claudeRecord("c", 1))
	l.Scan(context.Background())
	if calls != 2 {
		t.Fatalf("resolver survived scan boundary: %d", calls)
	}
	r := reportOf(l, time.Date(2026, 11, 17, 23, 0, 0, 0, time.UTC), 7, time.UTC, "", "")
	if len(r.Projects) != 2 || r.Projects[0].Key != "alpha" || r.Projects[0].Tokens.Output != 2 {
		t.Fatalf("project snapshot changed: %+v", r.Projects)
	}
}

func TestCursorOnlyAndUnchangedScanKeepNumericCache(t *testing.T) {
	dir := t.TempDir()
	path := filepath.Join(dir, "a.jsonl")
	appendLog(t, path, claudeRecord("s", 1))
	l := openTest(t, Options{Sources: []Source{{"claude", dir}}})
	l.Scan(context.Background())
	now := time.Date(2026, 11, 17, 23, 0, 0, 0, time.UTC)
	r := reportOf(l, now, 7, time.UTC, "", "")
	revision := l.revision
	l.Scan(context.Background())
	appendLog(t, path, claudeRecord("s", 1), "{\"type\":\"ignored\"}\n", "{broken}\n")
	l.Scan(context.Background())
	if l.revision != revision || len(l.reports) != 1 {
		t.Fatal("cursor-only/unchanged scan evicted numeric cache")
	}
	next := reportOf(l, now, 7, time.UTC, "", "")
	if next.ScanErrors != 1 || !next.Updated.After(r.Updated) || next.Total.Tokens.Output != 1 {
		t.Fatalf("cached status stale: %+v", next)
	}
	appendLog(t, path, claudeRecord("s", 2))
	l.Scan(context.Background())
	if l.revision == revision || len(l.reports) != 0 || reportOf(l, now, 7, time.UTC, "", "").Total.Tokens.Output != 2 {
		t.Fatal("streamed update did not invalidate")
	}
}

func waitFor(t *testing.T, condition func() bool) {
	t.Helper()
	deadline := time.NewTimer(3 * time.Second)
	defer deadline.Stop()
	tick := time.NewTicker(time.Millisecond)
	defer tick.Stop()
	for !condition() {
		select {
		case <-deadline.C:
			t.Fatal("timed out waiting for concurrent readers")
		case <-tick.C:
		}
	}
}

func blockReports(t *testing.T, l *Ledger) *sql.Conn {
	t.Helper()
	l.db.SetMaxOpenConns(1)
	conn, err := l.db.Conn(context.Background())
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { conn.Close() })
	return conn
}

func TestConcurrentReportSharesQueryAndIsolatesCancellation(t *testing.T) {
	l := openTest(t, Options{})
	conn := blockReports(t, l)
	now := time.Date(2026, 11, 17, 23, 0, 0, 0, time.UTC)
	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()
	first, second := make(chan error, 1), make(chan error, 1)
	go func() { _, err := l.Report(ctx, now, 7, time.UTC, "", ""); first <- err }()
	waitFor(t, func() bool { return l.db.Stats().WaitCount == 1 })
	go func() { _, err := l.Report(context.Background(), now, 7, time.UTC, "", ""); second <- err }()
	waitFor(t, func() bool {
		l.mu.RLock()
		defer l.mu.RUnlock()
		for _, f := range l.flights {
			return f.waiters == 2
		}
		return false
	})
	if l.db.Stats().WaitCount != 1 {
		t.Fatal("duplicate SQL query")
	}
	cancel()
	if err := <-first; err != context.Canceled {
		t.Fatalf("cancellation: %v", err)
	}
	conn.Close()
	if err := <-second; err != nil {
		t.Fatalf("other reader canceled: %v", err)
	}
	if len(l.reports) != 1 {
		t.Fatal("shared result not cached")
	}
}

func TestCanceledFlightDoesNotPoisonRetry(t *testing.T) {
	l := openTest(t, Options{})
	conn := blockReports(t, l)
	now := time.Now()
	ctx, cancel := context.WithCancel(context.Background())
	result := make(chan error, 1)
	go func() { _, err := l.Report(ctx, now, 7, time.UTC, "", ""); result <- err }()
	waitFor(t, func() bool { return l.db.Stats().WaitCount == 1 })
	l.mu.RLock()
	var abandoned *reportFlight
	for _, f := range l.flights {
		abandoned = f
	}
	l.mu.RUnlock()
	cancel()
	if err := <-result; err != context.Canceled {
		t.Fatalf("cancel: %v", err)
	}
	waitFor(t, func() bool {
		select {
		case <-abandoned.done:
			return true
		default:
			return false
		}
	})
	l.mu.RLock()
	n := len(l.flights)
	l.mu.RUnlock()
	if n != 0 {
		t.Fatal("abandoned flight still registered")
	}
	conn.Close()
	if _, err := l.Report(context.Background(), now, 7, time.UTC, "", ""); err != nil {
		t.Fatal(err)
	}
}

func TestImportUsesStableSnapshotAndRetriesRewrites(t *testing.T) {
	for _, rewrite := range []bool{false, true} {
		t.Run(fmt.Sprint("rewrite=", rewrite), func(t *testing.T) {
			dir := t.TempDir()
			path := filepath.Join(dir, "a.jsonl")
			appendLog(t, path, claudeRecord("a", 1))
			changed := false
			l := openTest(t, Options{Sources: []Source{{"claude", dir}}, Project: func(string) string {
				if !changed {
					changed = true
					if rewrite {
						if err := os.WriteFile(path, []byte(claudeRecord("b", 2)), 0600); err != nil {
							t.Fatal(err)
						}
					} else {
						appendLog(t, path, claudeRecord("b", 2))
					}
				}
				return "alpha"
			}})
			l.Scan(context.Background())
			want := int64(1)
			if rewrite {
				want = 0
			}
			if total(l).Output != want {
				t.Fatal("inconsistent source snapshot committed")
			}
			l.Scan(context.Background())
			want = 3
			if rewrite {
				want = 2
			}
			if total(l).Output != want {
				t.Fatal("source change not recovered on retry")
			}
		})
	}
}

func TestInFlightOldRevisionCannotPopulateCache(t *testing.T) {
	l := openTest(t, Options{})
	conn := blockReports(t, l)
	now := time.Now()
	result := make(chan error, 1)
	go func() { _, err := l.Report(context.Background(), now, 7, time.UTC, "", ""); result <- err }()
	waitFor(t, func() bool { return l.db.Stats().WaitCount == 1 })
	l.invalidateReports()
	conn.Close()
	if err := <-result; err != nil {
		t.Fatal(err)
	}
	l.mu.RLock()
	n := len(l.reports)
	l.mu.RUnlock()
	if n != 0 {
		t.Fatal("old generation repopulated cache")
	}
	if _, err := l.Report(context.Background(), now, 7, time.UTC, "", ""); err != nil {
		t.Fatal(err)
	}
}

func TestEmptySourceAndLegacyCursorUpgrade(t *testing.T) {
	dir := t.TempDir()
	path := filepath.Join(dir, "a.jsonl")
	appendLog(t, path, "")
	l := openTest(t, Options{Sources: []Source{{"claude", dir}}})
	l.Scan(context.Background())
	if l.scanErrors != 0 {
		t.Fatal("empty log rejected")
	}
	appendLog(t, path, claudeRecord("a", 1))
	l.Scan(context.Background())
	fs, err := l.fileState(context.Background(), path)
	if err != nil {
		t.Fatal(err)
	}
	fs.Identity, fs.Prefix, fs.Anchor = "", "", ""
	if err := l.writeBatch(context.Background(), nil, path, &fs); err != nil {
		t.Fatal(err)
	}
	l.Scan(context.Background())
	upgraded, err := l.fileState(context.Background(), path)
	if err != nil {
		t.Fatal(err)
	}
	if upgraded.Offset != fs.Offset || upgraded.Prefix == "" || upgraded.Identity == "" || total(l).Output != 1 {
		t.Fatal("legacy cursor failed to upgrade")
	}
}
