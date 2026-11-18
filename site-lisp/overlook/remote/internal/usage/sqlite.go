package usage

import (
	"context"
	"database/sql"
	"database/sql/driver"
	"encoding/json"
	"errors"
	"fmt"
	"net/url"
	"os"
	"path/filepath"
	"sync"
	"time"

	"modernc.org/sqlite"
)

var usageLocations sync.Map

func init() {
	sqlite.MustRegisterDeterministicScalarFunction("overlook_usage_slot", 2, func(_ *sqlite.FunctionContext, args []driver.Value) (driver.Value, error) {
		ns, ok := args[0].(int64)
		if !ok {
			return nil, errors.New("invalid usage timestamp")
		}
		zone, ok := args[1].(string)
		if !ok {
			return nil, errors.New("invalid usage time zone")
		}
		cached, ok := usageLocations.Load(zone)
		if !ok {
			loc, err := time.LoadLocation(zone)
			if err != nil {
				return nil, err
			}
			cached, _ = usageLocations.LoadOrStore(zone, loc)
		}
		at := time.Unix(0, ns).In(cached.(*time.Location))
		return int64((at.Year()*10000+int(at.Month())*100+at.Day())*100 + at.Hour()/2), nil
	})
}

const schema = `
CREATE TABLE IF NOT EXISTS meta (key TEXT PRIMARY KEY, value TEXT NOT NULL);
CREATE TABLE IF NOT EXISTS events (
 id TEXT PRIMARY KEY, at INTEGER NOT NULL, provider TEXT NOT NULL,
 session TEXT NOT NULL, model TEXT NOT NULL, root TEXT NOT NULL, project TEXT NOT NULL,
 input INTEGER NOT NULL CHECK(input>=0), cache_read INTEGER NOT NULL CHECK(cache_read>=0),
 cache_write INTEGER NOT NULL CHECK(cache_write>=0), output INTEGER NOT NULL CHECK(output>=0)
);
CREATE INDEX IF NOT EXISTS events_at ON events(at);
CREATE INDEX IF NOT EXISTS events_provider_at ON events(provider,at);
CREATE INDEX IF NOT EXISTS events_project_at ON events(project,at);
CREATE INDEX IF NOT EXISTS events_provider_project_at ON events(provider,project,at);
CREATE TABLE IF NOT EXISTS files (path TEXT PRIMARY KEY, state BLOB NOT NULL);
PRAGMA user_version=1;
`
const eventColumns = `id,at,provider,session,model,root,project,input,cache_read,cache_write,output`
const upsertEvent = `INSERT INTO events (` + eventColumns + `) VALUES (?,?,?,?,?,?,?,?,?,?,?)
ON CONFLICT(id) DO UPDATE SET
 input=max(events.input,excluded.input), cache_read=max(events.cache_read,excluded.cache_read),
 cache_write=max(events.cache_write,excluded.cache_write), output=max(events.output,excluded.output)
WHERE excluded.input>events.input OR excluded.cache_read>events.cache_read
 OR excluded.cache_write>events.cache_write OR excluded.output>events.output`

func Open(opts Options) (_ *Ledger, resultErr error) {
	l := &Ledger{opts: opts}
	path := opts.Path
	if path == "" {
		dir, err := os.MkdirTemp("", "overlook-usage-*")
		if err != nil {
			return nil, err
		}
		l.tempDir = dir
		path = filepath.Join(dir, "usage.sqlite")
	}
	defer func() {
		if resultErr != nil {
			l.Close()
		}
	}()
	abs, err := filepath.Abs(path)
	if err != nil {
		return nil, err
	}
	if err = os.MkdirAll(filepath.Dir(abs), 0700); err != nil {
		return nil, err
	}
	f, err := os.OpenFile(abs, os.O_CREATE|os.O_RDWR, 0600)
	if err != nil {
		return nil, err
	}
	if err = f.Close(); err != nil {
		return nil, err
	}
	u := url.URL{Scheme: "file", Path: abs}
	q := url.Values{}
	q.Add("_pragma", "busy_timeout(5000)")
	q.Add("_pragma", "journal_mode(WAL)")
	q.Add("_pragma", "synchronous(FULL)")
	u.RawQuery = q.Encode()
	l.db, err = sql.Open("sqlite", u.String())
	if err != nil {
		return nil, err
	}
	l.db.SetMaxOpenConns(4)
	l.db.SetMaxIdleConns(4)
	var version int
	if err = l.db.QueryRow("PRAGMA user_version").Scan(&version); err != nil {
		return nil, err
	}
	if version != 0 && version != 1 {
		return nil, fmt.Errorf("usage database: unsupported version %d", version)
	}
	tx, err := l.db.Begin()
	if err != nil {
		return nil, err
	}
	defer tx.Rollback()
	if _, err = tx.Exec(schema); err != nil {
		return nil, err
	}
	var initialized string
	err = tx.QueryRow("SELECT value FROM meta WHERE key='initialized'").Scan(&initialized)
	if errors.Is(err, sql.ErrNoRows) {
		if err = migrateJSON(tx, opts.LegacyPath); err != nil {
			return nil, err
		}
		if _, err = tx.Exec("INSERT INTO meta(key,value) VALUES('initialized','1')"); err != nil {
			return nil, err
		}
	} else if err != nil {
		return nil, err
	}
	if err = tx.Commit(); err != nil {
		return nil, err
	}
	var stamp string
	err = l.db.QueryRow("SELECT value FROM meta WHERE key='updated'").Scan(&stamp)
	if err == nil {
		l.updated, _ = time.Parse(time.RFC3339Nano, stamp)
	} else if !errors.Is(err, sql.ErrNoRows) {
		return nil, err
	}
	return l, nil
}

func (l *Ledger) Close() error {
	l.mu.Lock()
	for _, f := range l.flights {
		f.cancel()
	}
	l.revision++
	l.reports = nil
	l.mu.Unlock()
	var err error
	if l.db != nil {
		err = l.db.Close()
	}
	if l.tempDir != "" {
		err = errors.Join(err, os.RemoveAll(l.tempDir))
	}
	return err
}

func migrateJSON(tx *sql.Tx, path string) error {
	if path == "" {
		return nil
	}
	b, err := os.ReadFile(path)
	if errors.Is(err, os.ErrNotExist) {
		return nil
	}
	if err != nil {
		return err
	}
	var old disk
	if err = json.Unmarshal(b, &old); err != nil {
		return fmt.Errorf("usage JSON migration: %w", err)
	}
	if old.Format != 1 || old.Events == nil || old.Files == nil {
		return errors.New("usage JSON migration: unsupported format")
	}
	stmt, err := tx.Prepare(upsertEvent)
	if err != nil {
		return err
	}
	defer stmt.Close()
	for id, e := range old.Events {
		if id != e.ID || !e.Tokens.valid() || e.At.IsZero() {
			return errors.New("usage JSON migration: invalid event")
		}
		if _, err = execEvent(context.Background(), stmt, e); err != nil {
			return err
		}
	}
	for path, fs := range old.Files {
		if fs.Offset < 0 || fs.Size < 0 {
			return errors.New("usage JSON migration: invalid cursor")
		}
		if err = saveFile(context.Background(), tx, path, fs); err != nil {
			return err
		}
	}
	if !old.Updated.IsZero() {
		_, err = tx.Exec("INSERT INTO meta(key,value) VALUES('updated',?)", old.Updated.Format(time.RFC3339Nano))
	}
	return err
}

func execEvent(ctx context.Context, stmt *sql.Stmt, e Event) (bool, error) {
	result, err := stmt.ExecContext(ctx, e.ID, e.At.UnixNano(), e.Provider, e.Session, e.Model, e.Root, e.Project, e.Tokens.Input, e.Tokens.CacheRead, e.Tokens.CacheWrite, e.Tokens.Output)
	if err != nil {
		return false, err
	}
	n, err := result.RowsAffected()
	return n > 0, err
}
func saveFile(ctx context.Context, tx *sql.Tx, path string, fs fileState) error {
	b, err := json.Marshal(fs)
	if err != nil {
		return err
	}
	_, err = tx.ExecContext(ctx, "INSERT INTO files(path,state) VALUES(?,?) ON CONFLICT(path) DO UPDATE SET state=excluded.state", path, b)
	return err
}
func (l *Ledger) fileState(ctx context.Context, path string) (fileState, error) {
	var fs fileState
	var b []byte
	err := l.db.QueryRowContext(ctx, "SELECT state FROM files WHERE path=?", path).Scan(&b)
	if errors.Is(err, sql.ErrNoRows) {
		return fs, nil
	}
	if err != nil {
		return fs, err
	}
	err = json.Unmarshal(b, &fs)
	return fs, err
}

// writeBatch commits consumption and its source cursor together, so retries cannot skip or double count records.
func (l *Ledger) writeBatch(ctx context.Context, events []Event, path string, fs *fileState) error {
	tx, err := l.db.BeginTx(ctx, nil)
	if err != nil {
		return err
	}
	defer tx.Rollback()
	changed := false
	if len(events) > 0 {
		stmt, err := tx.PrepareContext(ctx, upsertEvent)
		if err != nil {
			return err
		}
		defer stmt.Close()
		for _, e := range events {
			wrote, err := execEvent(ctx, stmt, e)
			if err != nil {
				return err
			}
			changed = changed || wrote
		}
	}
	if fs != nil {
		if err = saveFile(ctx, tx, path, *fs); err != nil {
			return err
		}
	}
	_, err = tx.ExecContext(ctx, "INSERT INTO meta(key,value) VALUES('updated',?) ON CONFLICT(key) DO UPDATE SET value=excluded.value", time.Now().UTC().Format(time.RFC3339Nano))
	if err != nil {
		return err
	}
	if err = tx.Commit(); err != nil {
		return err
	}
	if changed {
		l.invalidateReports()
	}
	return nil
}

func (l *Ledger) invalidateReports() {
	l.mu.Lock()
	defer l.mu.Unlock()
	l.revision++
	l.reports = nil
}
