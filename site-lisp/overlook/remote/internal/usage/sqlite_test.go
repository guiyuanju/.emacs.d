package usage

import (
	"context"
	"encoding/json"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"
)

func TestJSONMigrationPreservesCountersAndRunsOnce(t *testing.T) {
	dir := t.TempDir()
	legacy := filepath.Join(dir, "usage.json")
	path := filepath.Join(dir, "logs", "session.jsonl")
	meta := "{\"type\":\"session_meta\",\"payload\":{\"id\":\"session-a\",\"cwd\":\"/work/alpha\"}}\n"
	first := codexCount("2026-11-17T01:00:00Z", 100, 40, 10)
	appendLog(t, path, meta, first)
	stat, _ := os.Stat(path)
	id := eventID("codex", "session-a", "60/40/0/10")
	old := disk{Format: 1, Updated: time.Now().UTC(), Events: map[string]Event{id: {ID: id, At: time.Date(2026, 11, 17, 1, 0, 0, 0, time.UTC), Provider: "codex", Session: "session-a", Project: "alpha", Tokens: Tokens{60, 40, 0, 10}}}, Files: map[string]fileState{path: {Offset: stat.Size(), Size: stat.Size(), Mtime: stat.ModTime().UnixNano(), Session: "session-a", Root: "/work/alpha", Previous: Tokens{60, 40, 0, 10}}}}
	data, _ := json.Marshal(old)
	os.WriteFile(legacy, data, 0600)
	opts := Options{Path: filepath.Join(dir, "usage.sqlite"), LegacyPath: legacy, Sources: []Source{{"codex", filepath.Join(dir, "logs")}}}
	l := openTest(t, opts)
	if total(l).Total() != 110 {
		t.Fatal("migration totals")
	}
	fs, err := l.fileState(context.Background(), path)
	if err != nil || fs.Offset != stat.Size() || fs.Previous.Output != 10 {
		t.Fatalf("cursor %+v %v", fs, err)
	}
	var mode string
	l.db.QueryRow("PRAGMA journal_mode").Scan(&mode)
	if mode != "wal" {
		t.Fatal(mode)
	}
	for _, suffix := range []string{"", "-wal", "-shm"} {
		info, err := os.Stat(opts.Path + suffix)
		if err == nil && info.Mode().Perm() != 0600 {
			t.Fatalf("unsafe permissions %s: %v", suffix, info.Mode())
		}
	}
	after, _ := os.ReadFile(legacy)
	if string(after) != string(data) {
		t.Fatal("legacy file changed")
	}
	l.Close()
	// A successfully initialized database must never re-import a stale or damaged backup.
	os.WriteFile(legacy, []byte("damaged backup"), 0600)
	l = openTest(t, opts)
	appendLog(t, path, codexCount("2026-11-17T02:00:00Z", 150, 60, 25))
	l.Scan(context.Background())
	if got := total(l); got != (Tokens{90, 60, 0, 25}) {
		t.Fatalf("migration/resume double counted: %+v", got)
	}
}

func TestMigrationFailureRollsBackAndCanRetry(t *testing.T) {
	dir := t.TempDir()
	legacy := filepath.Join(dir, "usage.json")
	db := filepath.Join(dir, "usage.sqlite")
	old := disk{Format: 1, Events: map[string]Event{"bad": {ID: "bad", At: time.Now(), Tokens: Tokens{Input: -1}}}, Files: map[string]fileState{}}
	b, _ := json.Marshal(old)
	os.WriteFile(legacy, b, 0600)
	if l, err := Open(Options{Path: db, LegacyPath: legacy}); err == nil {
		l.Close()
		t.Fatal("invalid migration accepted")
	}
	old.Events = map[string]Event{}
	b, _ = json.Marshal(old)
	os.WriteFile(legacy, b, 0600)
	l := openTest(t, Options{Path: db, LegacyPath: legacy})
	var n int
	if err := l.db.QueryRow("SELECT count(*) FROM events").Scan(&n); err != nil || n != 0 {
		t.Fatalf("partial migration remained: %d %v", n, err)
	}
}

func TestConsumptionAndCursorCommitAtomically(t *testing.T) {
	dir := t.TempDir()
	path := filepath.Join(dir, "logs", "a.jsonl")
	appendLog(t, path, "{\"type\":\"session_meta\",\"payload\":{\"id\":\"a\"}}\n", codexCount("2026-11-17T01:00:00Z", 100, 40, 10))
	l := openTest(t, Options{Path: filepath.Join(dir, "usage.sqlite"), Sources: []Source{{"codex", filepath.Join(dir, "logs")}}})
	if _, err := l.db.Exec("CREATE TRIGGER fail_cursor BEFORE INSERT ON files BEGIN SELECT RAISE(ABORT,'injected cursor failure'); END"); err != nil {
		t.Fatal(err)
	}
	l.Scan(context.Background())
	if total(l).Total() != 0 {
		t.Fatal("events committed without cursor")
	}
	fs, err := l.fileState(context.Background(), path)
	if err != nil || fs.Offset != 0 {
		t.Fatalf("cursor committed: %+v %v", fs, err)
	}
	l.db.Exec("DROP TRIGGER fail_cursor")
	l.Scan(context.Background())
	if total(l).Total() != 110 {
		t.Fatal("retry failed")
	}
	l.Scan(context.Background())
	if total(l).Total() != 110 {
		t.Fatal("retry duplicated records")
	}
}

func TestUnchangedScanDoesNotWriteDatabase(t *testing.T) {
	dir := t.TempDir()
	path := filepath.Join(dir, "logs", "a.jsonl")
	appendLog(t, path, "{\"type\":\"session_meta\",\"payload\":{\"id\":\"a\"}}\n", codexCount("2026-11-17T01:00:00Z", 100, 40, 10))
	l := openTest(t, Options{Path: filepath.Join(dir, "usage.sqlite"), Sources: []Source{{"codex", filepath.Join(dir, "logs")}}})
	l.Scan(context.Background())
	conn, err := l.db.Conn(context.Background())
	if err != nil {
		t.Fatal(err)
	}
	defer conn.Close()
	version := func() int {
		var n int
		if err := conn.QueryRowContext(context.Background(), "PRAGMA data_version").Scan(&n); err != nil {
			t.Fatal(err)
		}
		return n
	}
	before := version()
	l.Scan(context.Background())
	if version() != before {
		t.Fatal("unchanged scan wrote database")
	}
	appendLog(t, path, codexCount("2026-11-17T02:00:00Z", 150, 60, 25))
	l.Scan(context.Background())
	if version() == before {
		t.Fatal("changed scan did not commit")
	}
}

func TestQueryUsesRangeIndexAndHonorsCancellation(t *testing.T) {
	l := openTest(t, Options{})
	ctx := context.Background()
	for _, tc := range []struct{ provider, project, index string }{{"", "", "events_at"}, {"codex", "", "events_provider_at"}, {"", "alpha", "events_project_at"}, {"codex", "alpha", "events_"}} {
		where, args := eventFilter(tc.provider, tc.project)
		args = append(args, int64(0), time.Now().UnixNano())
		rows, err := l.db.QueryContext(ctx, "EXPLAIN QUERY PLAN "+aggregateQuery(where), append([]any{"UTC"}, args...)...)
		if err != nil {
			t.Fatal(err)
		}
		plan := ""
		for rows.Next() {
			var id, parent, unused int
			var detail string
			rows.Scan(&id, &parent, &unused, &detail)
			plan += detail
		}
		rows.Close()
		if !strings.Contains(plan, tc.index) || !strings.Contains(plan, "SEARCH") || !strings.Contains(plan, "at>?") {
			t.Fatalf("missing index %s: %s", tc.index, plan)
		}
	}
	canceled, cancel := context.WithCancel(ctx)
	cancel()
	if _, err := l.Report(canceled, time.Now(), 30, time.UTC, "", ""); err == nil {
		t.Fatal("canceled query continued")
	}
}

func TestReadersSeeCommittedSnapshotDuringWrite(t *testing.T) {
	l := openTest(t, Options{})
	ctx := context.Background()
	e := Event{ID: "a", At: time.Date(2026, 11, 17, 1, 0, 0, 0, time.UTC), Provider: "codex", Project: "alpha", Session: "s", Tokens: Tokens{Output: 1}}
	if err := l.writeBatch(ctx, []Event{e}, "", nil); err != nil {
		t.Fatal(err)
	}
	tx, err := l.db.BeginTx(ctx, nil)
	if err != nil {
		t.Fatal(err)
	}
	defer tx.Rollback()
	if _, err = tx.Exec("UPDATE events SET output=2 WHERE id='a'"); err != nil {
		t.Fatal(err)
	}
	if got := total(l).Output; got != 1 {
		t.Fatalf("reader saw uncommitted value %d", got)
	}
	if err = tx.Commit(); err != nil {
		t.Fatal(err)
	}
	l.invalidateReports()
	if got := total(l).Output; got != 2 {
		t.Fatalf("reader missed commit %d", got)
	}
}

func TestSessionLabelUsesFirstMatchingEvent(t *testing.T) {
	l := openTest(t, Options{})
	ctx := context.Background()
	now := time.Date(2026, 11, 17, 23, 0, 0, 0, time.UTC)
	for i, project := range []string{"alpha", "beta"} {
		e := Event{ID: project, At: now.Add(time.Duration(i-2) * time.Hour), Provider: "codex", Session: "same-session", Project: project, Tokens: Tokens{Output: 1}}
		if err := l.writeBatch(ctx, []Event{e}, "", nil); err != nil {
			t.Fatal(err)
		}
	}
	for range 3 {
		r := reportOf(l, now, 7, time.UTC, "", "")
		if len(r.Sessions) != 1 || r.Sessions[0].Label != "codex · alpha · same-ses" {
			t.Fatal("unstable session label")
		}
	}
}

func TestReportCacheInvalidatesOnCommitAndMinuteBoundary(t *testing.T) {
	l := openTest(t, Options{})
	ctx := context.Background()
	now := time.Date(2026, 11, 17, 23, 0, 0, 0, time.UTC)
	e := Event{ID: "a", At: now.Add(-time.Minute), Provider: "codex", Project: "alpha", Session: "s", Tokens: Tokens{Output: 1}}
	if err := l.writeBatch(ctx, []Event{e}, "", nil); err != nil {
		t.Fatal(err)
	}
	reportOf(l, now, 7, time.UTC, "", "")
	if len(l.reports) != 1 {
		t.Fatal("report not cached")
	}
	e.Tokens.Output = 2
	if err := l.writeBatch(ctx, []Event{e}, "", nil); err != nil {
		t.Fatal(err)
	}
	if len(l.reports) != 0 {
		t.Fatal("commit did not invalidate cache")
	}
	if r := reportOf(l, now, 7, time.UTC, "", ""); r.Total.Tokens.Output != 2 {
		t.Fatal("stale consumption")
	}
	// Timestamp cutoffs and midnight must move even with no new writes.
	e.ID = "future"
	e.At = now.Add(time.Minute)
	e.Tokens.Output = 3
	if err := l.writeBatch(ctx, []Event{e}, "", nil); err != nil {
		t.Fatal(err)
	}
	if r := reportOf(l, now, 7, time.UTC, "", ""); r.Total.Tokens.Output != 2 {
		t.Fatal("future record counted early")
	}
	if r := reportOf(l, now.Add(time.Minute), 7, time.UTC, "", ""); r.Total.Tokens.Output != 5 {
		t.Fatal("time cutoff remained cached")
	}
}

func TestSQLTimeSlotsPreserveDSTRepeatedAndMissingHours(t *testing.T) {
	l := openTest(t, Options{})
	ctx := context.Background()
	for _, tc := range []struct {
		at   string
		slot int64
	}{
		{"2026-11-01T05:30:00Z", 2026110100}, {"2026-11-01T06:30:00Z", 2026110100},
		{"2026-03-08T06:30:00Z", 2026030800}, {"2026-03-08T07:30:00Z", 2026030801},
	} {
		at, err := time.Parse(time.RFC3339, tc.at)
		if err != nil {
			t.Fatal(err)
		}
		var slot int64
		if err = l.db.QueryRowContext(ctx, "SELECT overlook_usage_slot(?,?)", at.UnixNano(), "America/New_York").Scan(&slot); err != nil {
			t.Fatal(err)
		}
		if slot != tc.slot {
			t.Fatalf("DST slot for %s: %d", tc.at, slot)
		}
	}
}
