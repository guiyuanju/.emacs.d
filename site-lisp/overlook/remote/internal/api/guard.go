package api

import (
	"container/list"
	"context"
	"crypto/hmac"
	"crypto/rand"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"net/http"
	"sync"
	"time"
)

// Receipt limits.
const (
	ReceiptLimit = 512
	ReceiptTTL   = time.Hour
	// lateWindow bounds how long a detached write may wait for Emacs after its HTTP call timed out.
	lateWindow = 10 * time.Minute
)

// Receipts replays successful writes by Idempotency-Key.
type Receipts struct {
	mu      sync.Mutex
	entries map[string]*receipt
	order   *list.List
	now     func() time.Time
	// version counts kept outcomes and clears, for Version.
	version uint64
}

type receipt struct {
	key       string
	signature string
	done      chan struct{}
	outcome   Outcome
	expires   time.Time
	el        *list.Element
}

// Outcome is a finished write; Keep marks it replayable (2xx and not a confirmation).
type Outcome struct {
	Status      int
	ContentType string
	Body        []byte
	Keep        bool
}

func (r *Receipts) init() {
	if r.entries == nil {
		r.entries = map[string]*receipt{}
		r.order = list.New()
	}
	if r.now == nil {
		r.now = time.Now
	}
}

// Clear forgets every finished receipt, as a new Emacs epoch requires.
func (r *Receipts) Clear() {
	r.mu.Lock()
	defer r.mu.Unlock()
	r.init()
	r.version++
	for key, e := range r.entries {
		select {
		case <-e.done:
			r.order.Remove(e.el)
			delete(r.entries, key)
		default:
		}
	}
}

// SavedReceipt is a kept outcome as written to the daemon's state file.
type SavedReceipt struct {
	Key         string    `json:"key"`
	Signature   string    `json:"signature"`
	Status      int       `json:"status"`
	ContentType string    `json:"contentType"`
	Body        []byte    `json:"body"`
	Expires     time.Time `json:"expires"`
}

// Version changes whenever the set of kept outcomes does.
func (r *Receipts) Version() uint64 {
	r.mu.Lock()
	defer r.mu.Unlock()
	return r.version
}

// Save lists the kept outcomes, oldest first; writes still in flight are not kept.
func (r *Receipts) Save() []SavedReceipt {
	r.mu.Lock()
	defer r.mu.Unlock()
	r.init()
	var out []SavedReceipt
	for el := r.order.Front(); el != nil; el = el.Next() {
		e := el.Value.(*receipt)
		select {
		case <-e.done:
			if e.outcome.Keep {
				out = append(out, SavedReceipt{Key: e.key, Signature: e.signature, Status: e.outcome.Status,
					ContentType: e.outcome.ContentType, Body: e.outcome.Body, Expires: e.expires})
			}
		default:
		}
	}
	return out
}

// Restore adds saved outcomes that have not expired.
func (r *Receipts) Restore(saved []SavedReceipt) {
	r.mu.Lock()
	defer r.mu.Unlock()
	r.init()
	now := r.now()
	for _, s := range saved {
		if _, ok := r.entries[s.Key]; ok || now.After(s.Expires) {
			continue
		}
		e := &receipt{key: s.Key, signature: s.Signature, done: make(chan struct{}), expires: s.Expires,
			outcome: Outcome{Status: s.Status, ContentType: s.ContentType, Body: s.Body, Keep: true}}
		close(e.done)
		e.el = r.order.PushBack(e)
		r.entries[s.Key] = e
	}
}

// Len is the number of receipts held, in flight included.
func (r *Receipts) Len() int {
	r.mu.Lock()
	defer r.mu.Unlock()
	return len(r.entries)
}

func (r *Receipts) expire(now time.Time) {
	for el := r.order.Front(); el != nil; {
		next := el.Next()
		e := el.Value.(*receipt)
		select {
		case <-e.done:
			if now.After(e.expires) || r.order.Len() > ReceiptLimit {
				r.order.Remove(el)
				delete(r.entries, e.key)
			}
		default:
		}
		el = next
	}
}

// Do runs fn once per key and signature: replays a kept outcome, waits for one in flight,
// and returns a conflict problem when the key was used with another signature.
// fn runs detached from ctx so a late result is still recorded; ctx only bounds the wait.
func (r *Receipts) Do(ctx context.Context, key, signature string, fn func(context.Context) Outcome) Outcome {
	detached, cancel := context.WithTimeout(context.WithoutCancel(ctx), lateWindow)
	if key == "" {
		done := make(chan Outcome, 1)
		go func() {
			defer cancel()
			done <- fn(detached)
		}()
		select {
		case o := <-done:
			return o
		case <-ctx.Done():
			return waitFailed(ctx)
		}
	}
	r.mu.Lock()
	r.init()
	now := r.now()
	r.expire(now)
	e, ok := r.entries[key]
	if ok && e.signature != signature {
		r.mu.Unlock()
		cancel()
		return problemOutcome(NewProblem(http.StatusConflict, CodeIdempotencyConflict,
			"This Idempotency-Key was used for a different request"))
	}
	if !ok {
		e = &receipt{key: key, signature: signature, done: make(chan struct{})}
		e.el = r.order.PushBack(e)
		r.entries[key] = e
		go func() {
			defer cancel()
			o := fn(detached)
			r.mu.Lock()
			e.outcome = o
			if o.Keep {
				e.expires = r.now().Add(ReceiptTTL)
				r.version++
			} else if r.entries[key] == e {
				r.order.Remove(e.el)
				delete(r.entries, key)
			}
			close(e.done)
			r.mu.Unlock()
		}()
	} else {
		cancel()
	}
	r.mu.Unlock()
	select {
	case <-e.done:
		return e.outcome
	case <-ctx.Done():
		return waitFailed(ctx)
	}
}

func waitFailed(ctx context.Context) Outcome {
	if ctx.Err() == context.DeadlineExceeded {
		return problemOutcome(NewProblem(http.StatusGatewayTimeout, CodeEmacsTimeout,
			"Emacs did not answer in time; retry to check delivery"))
	}
	return problemOutcome(NewProblem(499, CodeInternalError, "Request cancelled"))
}

func problemOutcome(p Problem) Outcome {
	body, _ := json.Marshal(p)
	return Outcome{Status: p.Status, ContentType: "application/problem+json", Body: body}
}

// Confirmer issues and checks confirmation tokens bound to operation state.
type Confirmer struct {
	secret []byte
}

// NewConfirmer returns a confirmer with a fresh secret.
func NewConfirmer() *Confirmer {
	secret := make([]byte, 32)
	_, _ = rand.Read(secret)
	return &Confirmer{secret: secret}
}

// ConfirmerWithSecret returns a confirmer that honours tokens issued with secret, as before a restart.
func ConfirmerWithSecret(secret []byte) *Confirmer {
	if len(secret) < 32 {
		return NewConfirmer()
	}
	return &Confirmer{secret: secret}
}

// Secret is the key tokens are signed with.
func (c *Confirmer) Secret() []byte { return c.secret }

// Token binds target, operation, input, state hash and accepted questions.
func (c *Confirmer) Token(target, operation, input, state string, questions []string) string {
	mac := hmac.New(sha256.New, c.secret)
	for _, part := range append([]string{target, operation, input, state}, questions...) {
		mac.Write([]byte(part))
		mac.Write([]byte{0})
	}
	return hex.EncodeToString(mac.Sum(nil))
}

// Valid reports whether token matches the current state and questions.
func (c *Confirmer) Valid(token, target, operation, input, state string, questions []string) bool {
	want := c.Token(target, operation, input, state, questions)
	return token != "" && hmac.Equal([]byte(token), []byte(want))
}
