package usage

import (
	"context"
	"database/sql"
	"fmt"
	"sort"
	"time"
)

type Bucket struct {
	Key      string `json:"key"`
	Label    string `json:"label"`
	Tokens   Tokens `json:"tokens"`
	Sessions int    `json:"sessions"`
	Events   int    `json:"events"`
}
type HeatCell struct {
	Weekday    int    `json:"weekday"`
	Hour       int    `json:"hour"`
	Tokens     Tokens `json:"tokens"`
	Days       int    `json:"days"`
	ActiveDays int    `json:"activeDays"`
}
type Report struct {
	Ready           bool       `json:"ready"`
	Updated         time.Time  `json:"updated"`
	First           *time.Time `json:"first"`
	Days            int        `json:"days"`
	Timezone        string     `json:"timezone"`
	Sources         []string   `json:"sources"`
	ScanErrors      int        `json:"scanErrors"`
	Warning         string     `json:"warning,omitempty"`
	Total           Bucket     `json:"total"`
	Previous        Tokens     `json:"previous"`
	Daily           []Bucket   `json:"daily"`
	Heat            []HeatCell `json:"heat"`
	Providers       []Bucket   `json:"providers"`
	Projects        []Bucket   `json:"projects"`
	Sessions        []Bucket   `json:"sessions"`
	ProviderOptions []string   `json:"providerOptions"`
	ProjectOptions  []string   `json:"projectOptions"`
}
type reportKey struct {
	days                    int
	zone, provider, project string
	minute                  int64
}

type tally struct {
	b        Bucket
	sessions map[string]bool
}

func (t *tally) add(e AggregateRow) {
	t.b.Tokens.Add(e.Tokens)
	t.b.Events += e.Events
	t.sessions[e.Provider+":"+e.Session] = true
	t.b.Sessions = len(t.sessions)
}
func add(m map[string]*tally, key, label string, e AggregateRow) {
	t := m[key]
	if t == nil {
		t = &tally{b: Bucket{Key: key, Label: label}, sessions: map[string]bool{}}
		m[key] = t
	}
	t.add(e)
}
func rank(m map[string]*tally) []Bucket {
	out := make([]Bucket, 0, len(m))
	for _, v := range m {
		out = append(out, v.b)
	}
	sort.Slice(out, func(i, j int) bool {
		a, b := out[i], out[j]
		if a.Tokens.Total() == b.Tokens.Total() {
			return a.Key < b.Key
		}
		return a.Tokens.Total() > b.Tokens.Total()
	})
	return out
}

// AggregateRow is a SQL group of events in one civil date and two-hour slot.
type AggregateRow struct {
	Slot                       int64
	Provider, Session, Project string
	Tokens                     Tokens
	Events                     int
	First                      time.Time
}

func (l *Ledger) queryReport(ctx context.Context, now time.Time, days int, loc *time.Location, provider, project string) (Report, error) {
	now = now.In(loc)
	start := time.Date(now.Year(), now.Month(), now.Day(), 0, 0, 0, 0, loc).AddDate(0, 0, 1-days)
	previous := start.AddDate(0, 0, -days)
	today := time.Date(now.Year(), now.Month(), now.Day(), 0, 0, 0, 0, loc)
	r := Report{Days: days, Timezone: loc.String(),
		Sources: []string{"Claude CLI", "Codex CLI"}, Daily: []Bucket{}, Heat: []HeatCell{}, Providers: []Bucket{}, Projects: []Bucket{}, Sessions: []Bucket{}}
	if l.db == nil {
		return r, nil
	}
	tx, err := l.db.BeginTx(ctx, &sql.TxOptions{ReadOnly: true})
	if err != nil {
		return r, err
	}
	defer tx.Rollback()
	where, args := eventFilter(provider, project)
	var first sql.NullInt64
	if err = tx.QueryRowContext(ctx, "SELECT min(at) FROM events WHERE "+where+" AND at<=?", append(append([]any{}, args...), now.UnixNano())...).Scan(&first); err != nil {
		return r, err
	}
	if first.Valid {
		at := time.Unix(0, first.Int64).UTC()
		r.First = &at
	}
	if r.ProviderOptions, err = optionValues(ctx, tx, "provider"); err != nil {
		return r, err
	}
	if r.ProjectOptions, err = optionValues(ctx, tx, "project"); err != nil {
		return r, err
	}

	// Keep the read snapshot only while loading SQL aggregates.
	query := aggregateQuery(where)
	queryArgs := append([]any{loc.String()}, args...)
	queryArgs = append(queryArgs, previous.UnixNano(), now.UnixNano())
	rows, err := tx.QueryContext(ctx, query, queryArgs...)
	if err != nil {
		return r, err
	}
	defer rows.Close()
	entries := []AggregateRow{}
	for rows.Next() {
		var e AggregateRow
		var ns int64
		if err = rows.Scan(&e.Slot, &e.Provider, &e.Session, &e.Project, &e.Tokens.Input, &e.Tokens.CacheRead, &e.Tokens.CacheWrite, &e.Tokens.Output, &e.Events, &ns); err != nil {
			return r, err
		}
		e.First = time.Unix(0, ns)

		entries = append(entries, e)
	}
	if err = rows.Err(); err != nil {
		return r, err
	}
	if err = rows.Close(); err != nil {
		return r, err
	}
	if err = tx.Commit(); err != nil {
		return r, err
	}
	return composeReport(r, entries, now, start, today), nil
}

func composeReport(r Report, entries []AggregateRow, now, start, today time.Time) Report {
	weekdays := map[string]int{}
	todayKey := today.Format("2006-01-02")
	daily, ps, pr, ss := map[string]*tally{}, map[string]*tally{}, map[string]*tally{}, map[string]*tally{}
	total := tally{sessions: map[string]bool{}}
	cells := [7][12]HeatCell{}
	active := [7][12]map[string]bool{}
	for w := range 7 {
		for h := range 12 {
			cells[w][h] = HeatCell{Weekday: w, Hour: h * 2}
			active[w][h] = map[string]bool{}
		}
	}
	var firstDay time.Time
	if r.First != nil {
		f := r.First.In(now.Location())
		firstDay = time.Date(f.Year(), f.Month(), f.Day(), 0, 0, 0, 0, now.Location())
	}
	for d := start; !d.After(now); d = d.AddDate(0, 0, 1) {
		key := d.Format("2006-01-02")
		weekdays[key] = (int(d.Weekday()) + 6) % 7
		daily[key] = &tally{b: Bucket{Key: key, Label: key}, sessions: map[string]bool{}}
		if r.First != nil && !d.Before(firstDay) && d.Before(today) {
			w := (int(d.Weekday()) + 6) % 7
			for h := range 12 {
				cells[w][h].Days++
			}
		}
	}
	for _, e := range entries {
		if e.First.Before(start) {
			r.Previous.Add(e.Tokens)
			continue
		}
		date := e.Slot / 100
		key := fmt.Sprintf("%04d-%02d-%02d", date/10000, date/100%100, date%100)
		total.add(e)
		add(daily, key, key, e)
		add(ps, e.Provider, e.Provider, e)
		add(pr, e.Project, e.Project, e)
		label := e.Provider + " · " + e.Project + " · " + e.Session[:min(8, len(e.Session))]
		add(ss, e.Provider+":"+e.Session, label, e)
		if key < todayKey {
			w, h := weekdays[key], int(e.Slot%100)
			cells[w][h].Tokens.Add(e.Tokens)
			active[w][h][key] = true
		}
	}
	r.Total = total.b
	for _, key := range sortedKeys(daily) {
		r.Daily = append(r.Daily, daily[key].b)
	}
	for w := range 7 {
		for h := range 12 {
			cells[w][h].ActiveDays = len(active[w][h])
			r.Heat = append(r.Heat, cells[w][h])
		}
	}
	r.Providers = rank(ps)
	r.Projects = rank(pr)
	r.Sessions = rank(ss)
	return r
}

func eventFilter(provider, project string) (string, []any) {
	where := "1=1"
	args := []any{}
	if provider != "" {
		where += " AND provider=?"
		args = append(args, provider)
	}
	if project != "" {
		where += " AND project=?"
		args = append(args, project)
	}
	return where, args
}
func optionValues(ctx context.Context, tx *sql.Tx, column string) ([]string, error) {
	// Column names are internal constants, never query parameters.
	if column != "provider" && column != "project" {
		return nil, fmt.Errorf("invalid usage option column")
	}
	rows, err := tx.QueryContext(ctx, "SELECT DISTINCT "+column+" FROM events ORDER BY "+column)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	out := []string{}
	for rows.Next() {
		var value string
		if err = rows.Scan(&value); err != nil {
			return nil, err
		}
		out = append(out, value)
	}
	return out, rows.Err()
}

func aggregateQuery(where string) string {
	return `SELECT overlook_usage_slot(at,?) AS slot,provider,session,project,
 sum(input),sum(cache_read),sum(cache_write),sum(output),count(*),min(at) AS first_at
 FROM events WHERE ` + where + ` AND at>=? AND at<=?
 GROUP BY slot,provider,session,project ORDER BY first_at,provider,project,session`
}

func sortedKeys[M ~map[string]V, V any](m M) []string {
	keys := make([]string, 0, len(m))
	for k := range m {
		keys = append(keys, k)
	}
	sort.Strings(keys)
	return keys
}
