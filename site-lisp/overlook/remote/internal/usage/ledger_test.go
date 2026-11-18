package usage

import (
	"context"
	"encoding/json"
	"os"
	"path/filepath"
	"testing"
	"time"
)

func appendLog(t *testing.T, path string, lines ...string) {
	t.Helper()
	if err := os.MkdirAll(filepath.Dir(path), 0700); err != nil {
		t.Fatal(err)
	}
	f, err := os.OpenFile(path, os.O_CREATE|os.O_APPEND|os.O_WRONLY, 0600)
	if err != nil {
		t.Fatal(err)
	}
	defer f.Close()
	for _, line := range lines {
		if _, err = f.WriteString(line); err != nil {
			t.Fatal(err)
		}
	}
}
func openTest(t *testing.T, opts Options) *Ledger {
	t.Helper()
	l, err := Open(opts)
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { l.Close() })
	return l
}
func total(l *Ledger) Tokens {
	return reportOf(l, time.Date(2026, 11, 17, 23, 0, 0, 0, time.UTC), 30, time.UTC, "", "").Total.Tokens
}
func codexCount(at string, input, cached, output int) string {
	b, _ := json.Marshal(map[string]any{"type": "event_msg", "timestamp": at, "payload": map[string]any{"type": "token_count", "info": map[string]any{"total_token_usage": map[string]int{"input_tokens": input, "cached_input_tokens": cached, "output_tokens": output, "reasoning_output_tokens": output / 2}}}})
	return string(b) + "\n"
}
func TestCodexIncrementalReplayArchiveAndRestart(t *testing.T) {
	dir := t.TempDir()
	path := filepath.Join(dir, "sessions", "a.jsonl")
	ledger := filepath.Join(dir, "state", "usage.sqlite")
	meta := "{\"type\":\"session_meta\",\"timestamp\":\"2026-11-17T00:00:00Z\",\"payload\":{\"id\":\"session-a\",\"cwd\":\"/workspace/alpha\"}}\n"
	first := codexCount("2026-11-17T01:00:00Z", 100, 40, 10)
	appendLog(t, path, meta, first, first)
	opts := Options{Path: ledger, Sources: []Source{{"codex", filepath.Join(dir, "sessions")}, {"codex", filepath.Join(dir, "archive")}}}
	l := openTest(t, opts)
	l.Scan(context.Background())
	if got := total(l); got != (Tokens{60, 40, 0, 10}) {
		t.Fatalf("initial: %+v", got)
	}
	l = openTest(t, opts)
	appendLog(t, path, codexCount("2026-11-17T02:00:00Z", 150, 60, 25))
	l.Scan(context.Background())
	if got := total(l); got != (Tokens{90, 60, 0, 25}) {
		t.Fatalf("incremental: %+v", got)
	}
	data, _ := os.ReadFile(path)
	appendLog(t, filepath.Join(dir, "archive", "copy.jsonl"), string(data))
	l.Scan(context.Background())
	if got := total(l); got != (Tokens{90, 60, 0, 25}) {
		t.Fatalf("archive duplicated: %+v", got)
	}
	info, _ := os.Stat(ledger)
	if info.Mode().Perm() != 0600 {
		t.Fatalf("mode %v", info.Mode())
	}
	if err := os.WriteFile(path, []byte(meta+first), 0600); err != nil {
		t.Fatal(err)
	}
	l.Scan(context.Background())
	if got := total(l).Total(); got != 175 {
		t.Fatalf("rewrite total %d", got)
	}
}
func TestClaudeStreamingPartialLinesAndProjectSnapshot(t *testing.T) {
	dir := t.TempDir()
	project := filepath.Join(dir, "alpha")
	os.MkdirAll(project, 0700)
	os.WriteFile(filepath.Join(project, "project.md"), []byte("---\nid: alpha\n"), 0600)
	root := filepath.Join(project, "repo")
	os.MkdirAll(root, 0700)
	path := filepath.Join(dir, "logs", "a.jsonl")
	record := func(output int) string {
		b, _ := json.Marshal(map[string]any{"type": "assistant", "timestamp": "2026-11-16T23:30:00Z", "sessionId": "claude-a", "cwd": root, "message": map[string]any{"id": "msg-1", "model": "claude-test", "usage": map[string]int{"input_tokens": 10, "cache_creation_input_tokens": 20, "cache_read_input_tokens": 30, "output_tokens": output}}})
		return string(b)
	}
	opts := Options{Path: filepath.Join(dir, "usage.sqlite"), Sources: []Source{{"claude", filepath.Join(dir, "logs")}}}
	l := openTest(t, opts)
	partial := record(4)
	appendLog(t, path, partial[:len(partial)/2])
	l.Scan(context.Background())
	if total(l).Total() != 0 {
		t.Fatal("counted unfinished line")
	}
	appendLog(t, path, partial[len(partial)/2:]+"\n", record(8)+"\n")
	l.Scan(context.Background())
	if got := total(l); got != (Tokens{10, 30, 20, 8}) {
		t.Fatalf("streamed message %+v", got)
	}
	r := reportOf(l, time.Date(2026, 11, 17, 23, 0, 0, 0, time.UTC), 7, time.UTC, "claude", "alpha")
	if r.Total.Events != 1 || r.Total.Sessions != 1 || len(r.Projects) != 1 {
		t.Fatalf("report %+v", r)
	}
	os.Remove(path)
	l = openTest(t, opts)
	l.Scan(context.Background())
	if total(l).Total() != 68 {
		t.Fatal("lost closed session")
	}
}
func TestCounterResetAndMalformedRecord(t *testing.T) {
	dir := t.TempDir()
	path := filepath.Join(dir, "a.jsonl")
	appendLog(t, path, "{\"type\":\"session_meta\",\"payload\":{\"id\":\"a\"}}\n", codexCount("2026-11-17T01:00:00Z", 100, 40, 10), "{bad}\n", codexCount("2026-11-17T02:00:00Z", 10, 4, 1), codexCount("2026-11-17T03:00:00Z", 20, 8, 2))
	l := openTest(t, Options{Sources: []Source{{"codex", dir}}})
	l.Scan(context.Background())
	if total(l).Total() != 121 {
		t.Fatalf("reset %+v", total(l))
	}
	if reportOf(l, time.Now(), 7, time.UTC, "", "").ScanErrors != 1 {
		t.Fatal("missing invalid-file warning")
	}
}
func TestReportTimezoneFiltersAndHeatDenominator(t *testing.T) {
	l := openTest(t, Options{})
	add := func(id, at, provider, project string, n int64) {
		v, _ := time.Parse(time.RFC3339, at)
		if err := l.writeBatch(context.Background(), []Event{{ID: id, At: v, Provider: provider, Project: project, Session: id, Tokens: Tokens{Output: n}}}, "", nil); err != nil {
			t.Fatal(err)
		}
	}
	add("a", "2026-11-09T23:30:00Z", "claude", "alpha", 100)
	add("b", "2026-11-16T23:30:00Z", "codex", "beta", 200)
	add("c", "2026-11-17T01:00:00Z", "claude", "alpha", 50)
	loc, _ := time.LoadLocation("Asia/Tokyo")
	now := time.Date(2026, 11, 17, 10, 0, 0, 0, loc)
	r := reportOf(l, now, 14, loc, "", "")
	if r.Total.Tokens.Output != 350 || len(r.Daily) != 14 || r.Providers[0].Key != "codex" {
		t.Fatalf("totals %+v", r)
	}
	cell := r.Heat[1*12+4]
	if cell.Hour != 8 || cell.Days != 1 || cell.ActiveDays != 1 || cell.Tokens.Output != 100 {
		t.Fatalf("Tuesday 08–10: %+v", cell)
	}
	filtered := reportOf(l, now, 14, loc, "claude", "alpha")
	if filtered.Total.Tokens.Output != 150 || len(filtered.Projects) != 1 || len(filtered.ProviderOptions) != 2 {
		t.Fatal("filter broke options or counts")
	}
}
func TestCivilDaysAcrossDST(t *testing.T) {
	l := openTest(t, Options{})
	loc, _ := time.LoadLocation("America/New_York")
	r := reportOf(l, time.Date(2026, 11, 2, 12, 0, 0, 0, loc), 7, loc, "", "")
	if len(r.Daily) != 7 || r.Daily[6].Key != "2026-11-02" || r.Daily[0].Key != "2026-10-27" {
		t.Fatalf("DST dates %+v", r.Daily)
	}
}

func TestTokenComponentsDoNotDoubleCountCacheOrReasoning(t *testing.T) {
	got := (tokenUsage{Input: 100, Cached: 40, CodexWrite: 10, Output: 20}).tokens("codex")
	if got != (Tokens{50, 40, 10, 20}) || got.Total() != 120 {
		t.Fatalf("Codex cache counted twice: %+v", got)
	}
	got = (tokenUsage{Input: 5, CacheRead: 40, CacheWrite: 10, Output: 20}).tokens("claude")
	if got.Total() != 75 {
		t.Fatalf("Claude components: %+v", got)
	}
}
func TestWorktreeAndNestedDirectoryResolveToWorkspaceProject(t *testing.T) {
	base := t.TempDir()
	project := filepath.Join(base, "example")
	repo := filepath.Join(project, "repo")
	gd := filepath.Join(repo, ".git", "worktrees", "feature")
	wt := filepath.Join(base, "feature")
	sub := filepath.Join(wt, "src")
	for _, dir := range []string{gd, sub} {
		if err := os.MkdirAll(dir, 0700); err != nil {
			t.Fatal(err)
		}
	}
	os.WriteFile(filepath.Join(project, "project.md"), []byte("---\nid: example\n---\n"), 0600)
	os.WriteFile(filepath.Join(wt, ".git"), []byte("gitdir: "+gd+"\n"), 0600)
	os.WriteFile(filepath.Join(gd, "commondir"), []byte("../..\n"), 0600)
	if got := projectFromRoot(sub); got != "example" {
		t.Fatalf("worktree project=%s", got)
	}
}

func TestUnavailableLedgerDoesNotOverwriteHistory(t *testing.T) {
	path := filepath.Join(t.TempDir(), "usage.sqlite")
	os.WriteFile(path, []byte("damaged history"), 0600)
	if _, err := Open(Options{Path: path}); err == nil {
		t.Fatal("corrupt ledger silently accepted")
	}
	l := Unavailable("History unavailable")
	l.Run(context.Background())
	r := reportOf(l, time.Now(), 7, time.UTC, "", "")
	if r.Ready || r.Warning != "History unavailable" {
		t.Fatalf("missing degradation: %+v", r)
	}
	b, _ := os.ReadFile(path)
	if string(b) != "damaged history" {
		t.Fatal("corrupt ledger overwritten")
	}
}

func reportOf(l *Ledger, now time.Time, days int, loc *time.Location, provider, project string) Report {
	r, err := l.Report(context.Background(), now, days, loc, provider, project)
	if err != nil {
		panic(err)
	}
	return r
}
