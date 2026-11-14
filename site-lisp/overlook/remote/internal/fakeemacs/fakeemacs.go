// Package fakeemacs is a bridge client that replays testdata/fixtures and answers
// daemon requests from canned responses, for daemon and browser tests.
package fakeemacs

import (
	"bufio"
	"bytes"
	"context"
	"encoding/json"
	"fmt"
	"io"
	"net"
	"os"
	"path/filepath"
	"reflect"
	"sync"
	"time"

	"github.com/guiyuanju/overlook/remote/internal/bridge"
)

// Placeholder is replaced by the absolute fixtures directory in every fixture file.
const Placeholder = "${FIXTURES}"

// Step is one line of live.ndjson: a message sent DelayMs after the previous step.
type Step struct {
	DelayMs int            `json:"delayMs"`
	Message bridge.Message `json:"message"`
}

// Response answers a daemon request whose params contain every key of Match with equal values.
type Response struct {
	Match  map[string]json.RawMessage `json:"match,omitempty"`
	Result json.RawMessage            `json:"result,omitempty"`
	Error  *bridge.Error              `json:"error,omitempty"`
}

// Fixtures is a loaded fixture set.
type Fixtures struct {
	Dir       string
	Hello     bridge.Message
	Sync      bridge.Message
	Events    []bridge.Message
	Live      []Step
	Responses map[string][]Response
}

// Load reads a fixture directory, substituting Placeholder.
func Load(dir string) (*Fixtures, error) {
	abs, err := filepath.Abs(dir)
	if err != nil {
		return nil, err
	}
	read := func(name string) ([]byte, error) {
		data, err := os.ReadFile(filepath.Join(abs, name))
		if err != nil {
			return nil, err
		}
		quoted, _ := json.Marshal(abs)
		return bytes.ReplaceAll(data, []byte(Placeholder), quoted[1:len(quoted)-1]), nil
	}
	f := &Fixtures{Dir: abs}
	for name, into := range map[string]any{"hello.json": &f.Hello, "sync.json": &f.Sync, "responses.json": &f.Responses} {
		data, err := read(name)
		if err != nil {
			return nil, err
		}
		if err := strictUnmarshal(data, into); err != nil {
			return nil, fmt.Errorf("%s: %w", name, err)
		}
	}
	data, err := read("events.ndjson")
	if err != nil {
		return nil, err
	}
	if f.Events, err = lines[bridge.Message](data); err != nil {
		return nil, fmt.Errorf("events.ndjson: %w", err)
	}
	if data, err = read("live.ndjson"); err != nil {
		return nil, err
	}
	if f.Live, err = lines[Step](data); err != nil {
		return nil, fmt.Errorf("live.ndjson: %w", err)
	}
	return f, nil
}

// Respond returns the first canned response for method whose Match fits params.
func (f *Fixtures) Respond(method string, params json.RawMessage) (Response, bool) {
	var got map[string]json.RawMessage
	_ = json.Unmarshal(params, &got)
	for _, r := range f.Responses[method] {
		if matches(r.Match, got) {
			return r, true
		}
	}
	return Response{}, false
}

func matches(want, got map[string]json.RawMessage) bool {
	for key, w := range want {
		var a, b any
		if json.Unmarshal(w, &a) != nil {
			return false
		}
		if g, ok := got[key]; ok {
			_ = json.Unmarshal(g, &b)
		}
		if isEmptyArray(a) && b == nil {
			continue
		}
		if !reflect.DeepEqual(a, b) {
			return false
		}
	}
	return true
}

func isEmptyArray(v any) bool {
	a, ok := v.([]any)
	return ok && len(a) == 0
}

func lines[T any](data []byte) ([]T, error) {
	var out []T
	sc := bufio.NewScanner(bytes.NewReader(data))
	sc.Buffer(nil, bridge.MaxInboundLine)
	for n := 1; sc.Scan(); n++ {
		if len(bytes.TrimSpace(sc.Bytes())) == 0 {
			continue
		}
		var v T
		if err := strictUnmarshal(sc.Bytes(), &v); err != nil {
			return nil, fmt.Errorf("line %d: %w", n, err)
		}
		out = append(out, v)
	}
	return out, sc.Err()
}

func strictUnmarshal(data []byte, v any) error {
	dec := json.NewDecoder(bytes.NewReader(data))
	dec.DisallowUnknownFields()
	return dec.Decode(v)
}

// Fake connects to a daemon socket and plays Fixtures.
type Fake struct {
	Socket   string
	Fixtures *Fixtures
	// Calls receives every daemon request and notification, if non-nil; sends block until read.
	Calls chan<- bridge.Message
	// Speed divides live step delays; 0 means 1.
	Speed float64
	// LiveDelay is the wait before live steps play by themselves; negative waits for PlayLive.
	LiveDelay time.Duration
	// Lost is reported in hello.
	Lost int
	// Resume skips replaying the fixture events, like an Emacs reconnecting to a restarted daemon.
	Resume bool

	once   sync.Once
	replay chan struct{}
	wmu    sync.Mutex
	conn   net.Conn
}

func (f *Fake) init() {
	f.once.Do(func() { f.replay = make(chan struct{}, 1) })
}

// PlayLive plays live.ndjson (again) as soon as the fake is idle.
func (f *Fake) PlayLive() {
	f.init()
	select {
	case f.replay <- struct{}{}:
	default:
	}
}

// Run connects, says hello, syncs, replays events, then plays live steps while answering requests until ctx ends.
func (f *Fake) Run(ctx context.Context) error {
	f.init()
	conn, err := dial(ctx, f.Socket)
	if err != nil {
		return err
	}
	f.conn = conn
	defer conn.Close()
	stop := context.AfterFunc(ctx, func() { conn.Close() })
	defer stop()

	helloDone := make(chan *bridge.Message, 1)
	readErr := make(chan error, 1)
	go func() { readErr <- f.read(ctx, conn, helloDone) }()

	hello := f.Fixtures.Hello
	if f.Lost > 0 {
		var p bridge.HelloParams
		_ = json.Unmarshal(hello.Params, &p)
		p.Lost = f.Lost
		hello.Params, _ = json.Marshal(p)
	}
	if err := f.send(hello); err != nil {
		return err
	}
	select {
	case resp := <-helloDone:
		if resp.Error != nil {
			return resp.Error
		}
	case err := <-readErr:
		return fmt.Errorf("fakeemacs: before hello result: %w", err)
	case <-ctx.Done():
		return nil
	}
	if err := f.send(f.Fixtures.Sync); err != nil {
		return err
	}
	for _, m := range f.Fixtures.Events {
		if f.Resume {
			break
		}
		if err := f.send(m); err != nil {
			return err
		}
	}
	var auto <-chan time.Time
	if f.LiveDelay >= 0 {
		auto = time.After(f.LiveDelay)
	}
	for {
		select {
		case <-ctx.Done():
			return nil
		case err := <-readErr:
			if ctx.Err() != nil {
				return nil
			}
			return err
		case <-auto:
			auto = nil
		case <-f.replay:
		}
		if err := f.playLive(ctx); err != nil {
			if ctx.Err() != nil {
				return nil
			}
			return err
		}
	}
}

func dial(ctx context.Context, socket string) (net.Conn, error) {
	var d net.Dialer
	for {
		conn, err := d.DialContext(ctx, "unix", socket)
		if err == nil {
			return conn, nil
		}
		select {
		case <-ctx.Done():
			return nil, ctx.Err()
		case <-time.After(50 * time.Millisecond):
		}
	}
}

func (f *Fake) playLive(ctx context.Context) error {
	for _, step := range f.Fixtures.Live {
		select {
		case <-ctx.Done():
			return ctx.Err()
		case <-time.After(f.Delay(step)):
		}
		if err := f.send(step.Message); err != nil {
			return err
		}
	}
	return nil
}

func (f *Fake) send(m bridge.Message) error {
	m.JSONRPC = "2.0"
	data, err := json.Marshal(m)
	if err != nil {
		return err
	}
	var buf bytes.Buffer
	if err := json.Compact(&buf, data); err != nil {
		return err
	}
	buf.WriteByte('\n')
	f.wmu.Lock()
	defer f.wmu.Unlock()
	_, err = f.conn.Write(buf.Bytes())
	return err
}

// read answers daemon requests and forwards traffic to Calls until the connection ends.
func (f *Fake) read(ctx context.Context, conn net.Conn, helloDone chan<- *bridge.Message) error {
	sc := bufio.NewScanner(conn)
	sc.Buffer(nil, bridge.MaxInboundLine)
	for sc.Scan() {
		var m bridge.Message
		if err := json.Unmarshal(sc.Bytes(), &m); err != nil {
			return fmt.Errorf("fakeemacs: bad line from daemon: %w", err)
		}
		if m.Method == "" {
			if string(m.ID) == string(f.Fixtures.Hello.ID) {
				helloDone <- &m
			}
			continue
		}
		if f.Calls != nil {
			select {
			case f.Calls <- m:
			case <-ctx.Done():
				return nil
			}
		}
		if len(m.ID) == 0 {
			continue
		}
		reply := bridge.Message{ID: m.ID}
		if r, ok := f.Fixtures.Respond(m.Method, m.Params); ok {
			reply.Result, reply.Error = r.Result, r.Error
		} else {
			reply.Error = bridge.NewError(500, "internal_error", "fakeemacs has no response for "+m.Method)
		}
		if err := f.send(reply); err != nil {
			return err
		}
	}
	if err := sc.Err(); err != nil {
		return err
	}
	return io.EOF
}

// Delay returns a step's delay scaled by Speed.
func (f *Fake) Delay(s Step) time.Duration {
	speed := f.Speed
	if speed <= 0 {
		speed = 1
	}
	return time.Duration(float64(s.DelayMs)/speed) * time.Millisecond
}
