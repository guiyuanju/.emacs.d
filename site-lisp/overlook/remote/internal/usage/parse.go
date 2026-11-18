package usage

import (
	"errors"
	"fmt"
	"time"
)

func parseRecord(provider string, fs *fileState, r logRecord) (Event, bool, error) {
	if provider == "codex" {
		if r.Type == "session_meta" {
			fs.Session = r.Payload.ID
			fs.Root = r.Payload.Root
		}
		if r.Type == "turn_context" {
			fs.Model = r.Payload.Model
			if r.Payload.Root != "" {
				fs.Root = r.Payload.Root
			}
		}
	} else {
		if r.Session != "" {
			fs.Session = r.Session
		}
		if r.Root != "" {
			fs.Root = r.Root
		}
	}
	if fs.Session == "" || r.At.IsZero() {
		return Event{}, false, nil
	}
	e := Event{At: r.At, Provider: provider, Session: fs.Session, Root: fs.Root, Model: fs.Model}
	if provider == "claude" {
		if r.Type != "assistant" || r.Message.Usage == nil || r.Message.ID == "" {
			return Event{}, false, nil
		}
		e.ID = eventID(provider, fs.Session, r.Message.ID)
		e.Model = r.Message.Model
		e.Tokens = r.Message.Usage.tokens(provider)
	} else {
		if r.Type != "event_msg" || r.Payload.Type != "token_count" || r.Payload.Info == nil || r.Payload.Info.Total == nil {
			return Event{}, false, nil
		}
		total := r.Payload.Info.Total.tokens(provider)
		if !total.valid() {
			return Event{}, false, errors.New("usage: invalid token counters")
		}
		// Cumulative counters make repeated token_count events and replayed files harmless.
		prev := fs.Previous
		if total.Input < prev.Input || total.CacheRead < prev.CacheRead || total.CacheWrite < prev.CacheWrite || total.Output < prev.Output {
			// A counter reset establishes a new baseline; its provenance is unknown.
			fs.Previous = total
			return Event{}, false, nil
		}
		fs.Previous = total
		e.Tokens = Tokens{total.Input - prev.Input, total.CacheRead - prev.CacheRead, total.CacheWrite - prev.CacheWrite, total.Output - prev.Output}
		// A stable cumulative checkpoint deduplicates copies moved into archived_sessions.
		e.ID = eventID(provider, fs.Session, fmt.Sprintf("%d/%d/%d/%d", total.Input, total.CacheRead, total.CacheWrite, total.Output))
	}
	if !e.Tokens.valid() {
		return Event{}, false, errors.New("usage: invalid token counters")
	}
	if e.Tokens.Total() == 0 {
		return Event{}, false, nil
	}

	return e, true, nil
}

type tokenUsage struct {
	Input      int64 `json:"input_tokens"`
	Cached     int64 `json:"cached_input_tokens"`
	CacheRead  int64 `json:"cache_read_input_tokens"`
	CacheWrite int64 `json:"cache_creation_input_tokens"`
	CodexWrite int64 `json:"cache_write_input_tokens"`
	Output     int64 `json:"output_tokens"`
}

func (t tokenUsage) tokens(provider string) Tokens {
	if provider == "codex" {
		return Tokens{Input: t.Input - t.Cached - t.CodexWrite, CacheRead: t.Cached, CacheWrite: t.CodexWrite, Output: t.Output}
	}
	return Tokens{Input: t.Input, CacheRead: t.CacheRead, CacheWrite: t.CacheWrite, Output: t.Output}
}

type logRecord struct {
	Type    string    `json:"type"`
	At      time.Time `json:"timestamp"`
	Session string    `json:"sessionId"`
	Root    string    `json:"cwd"`
	UUID    string    `json:"uuid"`
	Message struct {
		ID    string      `json:"id"`
		Model string      `json:"model"`
		Usage *tokenUsage `json:"usage"`
	} `json:"message"`
	Payload struct {
		Type  string `json:"type"`
		ID    string `json:"id"`
		Root  string `json:"cwd"`
		Model string `json:"model"`
		Info  *struct {
			Total *tokenUsage `json:"total_token_usage"`
		} `json:"info"`
	} `json:"payload"`
}
