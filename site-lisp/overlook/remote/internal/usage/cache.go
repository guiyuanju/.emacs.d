package usage

import (
	"context"
	"time"
)

type flightKey struct {
	reportKey
	revision uint64
}

type reportFlight struct {
	done    chan struct{}
	cancel  context.CancelFunc
	waiters int
	report  Report
	err     error
}

// Report shares identical queries; each caller can cancel without interrupting other readers.
func (l *Ledger) Report(ctx context.Context, now time.Time, days int, loc *time.Location, provider, project string) (Report, error) {
	if err := ctx.Err(); err != nil {
		return Report{}, err
	}
	key := reportKey{days: days, zone: loc.String(), provider: provider, project: project, minute: now.Unix() / 60}
	l.mu.Lock()
	if r, ok := l.reports[key]; ok {
		r = l.reportStatus(r)
		l.mu.Unlock()
		return r, nil
	}
	fk := flightKey{key, l.revision}
	f := l.flights[fk]
	if f == nil {
		queryCtx, cancel := context.WithCancel(context.WithoutCancel(ctx))
		f = &reportFlight{done: make(chan struct{}), cancel: cancel}
		if l.flights == nil {
			l.flights = map[flightKey]*reportFlight{}
		}
		l.flights[fk] = f
		go l.runReport(queryCtx, fk, f, now, days, loc, provider, project)
	}
	f.waiters++
	l.mu.Unlock()
	select {
	case <-ctx.Done():
		l.mu.Lock()
		f.waiters--
		if f.waiters == 0 {
			f.cancel()
			if l.flights[fk] == f {
				delete(l.flights, fk)
			}
		}
		l.mu.Unlock()
		return Report{}, ctx.Err()
	case <-f.done:
		if err := ctx.Err(); err != nil {
			return Report{}, err
		}
		l.mu.RLock()
		r := l.reportStatus(f.report)
		l.mu.RUnlock()
		return r, f.err
	}
}

func (l *Ledger) runReport(ctx context.Context, key flightKey, f *reportFlight, now time.Time, days int, loc *time.Location, provider, project string) {
	defer f.cancel()
	r, err := l.queryReport(ctx, now, days, loc, provider, project)
	l.mu.Lock()
	defer l.mu.Unlock()
	f.report, f.err = r, err
	if l.flights[key] == f {
		delete(l.flights, key)
		if err == nil && ctx.Err() == nil && l.revision == key.revision {
			if l.reports == nil {
				l.reports = map[reportKey]Report{}
			}
			// Expired minute entries cannot be used by current requests.
			for cached := range l.reports {
				if cached.minute != key.minute {
					delete(l.reports, cached)
				}
			}
			if len(l.reports) >= 8 {
				for cached := range l.reports {
					delete(l.reports, cached)
					break
				}
			}
			l.reports[key.reportKey] = r
		}
	}
	close(f.done)
}

// reportStatus overlays scan metadata without invalidating the numeric report; mu must be held.
func (l *Ledger) reportStatus(r Report) Report {
	r.Ready, r.Updated, r.ScanErrors, r.Warning = l.ready, l.updated, l.scanErrors, l.lastError
	return r
}
