package bridge

import (
	"bufio"
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"log/slog"
	"net"
	"os"
	"path/filepath"
	"strconv"
	"sync"
	"sync/atomic"
	"time"
)

// Connection timing.
const (
	helloTimeout = 10 * time.Second
	writeTimeout = 10 * time.Second
	// recoverPrefix is how much of an over-long line is kept to find its id.
	recoverPrefix = 64 << 10
)

// Sink receives Emacs's state in arrival order, on one goroutine.
type Sink interface {
	// Connected is called after a valid hello and returns the history epoch to report.
	Connected(hello HelloParams) (historyEpoch string)
	Sync(SyncParams)
	SetDashboard(DashboardSetParams)
	SetConversation(ConversationSetParams)
	RemoveConversation(ConversationParams)
	Event(Event)
	Disconnected()
}

// Watcher follows the Emacs process behind the connection.
type Watcher interface {
	// Hello is called after a valid hello with Emacs's pid.
	Hello(pid int)
	// Bye is called when Emacs says the coming disconnect is intentional.
	Bye()
	// Gone is called when the active connection ends.
	Gone()
}

// Server listens on the bridge socket and holds the one active Emacs connection.
type Server struct {
	path    string
	version string
	sink    Sink
	log     *slog.Logger

	// applyMu orders sink calls and switches of the active connection.
	applyMu sync.Mutex
	mu      sync.Mutex
	active  *conn
	ln      net.Listener
	nextID  atomic.Int64
	wg      sync.WaitGroup
	watcher Watcher
}

// SetWatcher sets w to follow the Emacs process; call it before Serve.
func (s *Server) SetWatcher(w Watcher) {
	s.watcher = w
}

// NewServer returns a server for socket path that feeds sink.
func NewServer(path, version string, sink Sink, log *slog.Logger) *Server {
	if log == nil {
		log = slog.New(slog.NewTextHandler(io.Discard, nil))
	}
	return &Server{path: path, version: version, sink: sink, log: log}
}

// Listen creates the 0700 directory and the 0600 socket, removing a stale socket file.
func (s *Server) Listen() error {
	s.mu.Lock()
	defer s.mu.Unlock()
	if s.ln != nil {
		return nil
	}
	dir := filepath.Dir(s.path)
	if err := os.MkdirAll(dir, 0o700); err != nil {
		return err
	}
	if err := os.Chmod(dir, 0o700); err != nil {
		return err
	}
	if _, err := os.Lstat(s.path); err == nil {
		if c, err := net.DialTimeout("unix", s.path, time.Second); err == nil {
			c.Close()
			return fmt.Errorf("bridge: %s is in use by another daemon", s.path)
		}
		if err := os.Remove(s.path); err != nil {
			return err
		}
	}
	ln, err := net.Listen("unix", s.path)
	if err != nil {
		return err
	}
	if err := os.Chmod(s.path, 0o600); err != nil {
		ln.Close()
		return err
	}
	s.ln = ln
	return nil
}

// Serve listens until ctx ends, replacing the active connection when a new hello succeeds.
func (s *Server) Serve(ctx context.Context) error {
	if err := s.Listen(); err != nil {
		return err
	}
	s.mu.Lock()
	ln := s.ln
	s.mu.Unlock()
	stop := context.AfterFunc(ctx, func() {
		ln.Close()
		s.closeActive()
	})
	defer stop()
	for {
		nc, err := ln.Accept()
		if err != nil {
			if ctx.Err() != nil || errors.Is(err, net.ErrClosed) {
				s.closeActive()
				s.wg.Wait()
				return nil
			}
			s.log.Warn("bridge accept", "err", err)
			time.Sleep(100 * time.Millisecond)
			continue
		}
		s.wg.Add(1)
		go func() {
			defer s.wg.Done()
			s.handle(nc)
		}()
	}
}

func (s *Server) closeActive() {
	s.mu.Lock()
	c := s.active
	s.mu.Unlock()
	if c != nil {
		c.close()
	}
}

// Online reports whether an Emacs connection has completed sync.
func (s *Server) Online() bool {
	return s.current() != nil
}

func (s *Server) current() *conn {
	s.mu.Lock()
	defer s.mu.Unlock()
	if s.active != nil && s.active.synced.Load() {
		return s.active
	}
	return nil
}

// Timeout returns how long the daemon waits for Emacs on method.
func Timeout(method string) time.Duration {
	if d, ok := Timeouts[method]; ok {
		return d
	}
	return DefaultTimeout
}

// Call sends a request and blocks until Emacs answers, disconnects or ctx ends.
// Callers apply Timeouts themselves, so a late result can still be recorded as a receipt.
func (s *Server) Call(ctx context.Context, method string, params, result any) error {
	c := s.current()
	if c == nil {
		return ErrOffline
	}
	if params == nil {
		params = Empty{}
	}
	raw, err := json.Marshal(params)
	if err != nil {
		return err
	}
	id := s.nextID.Add(1)
	data, err := json.Marshal(Message{JSONRPC: "2.0", ID: json.RawMessage(strconv.FormatInt(id, 10)), Method: method, Params: raw})
	if err != nil {
		return err
	}
	if len(data) > MaxOutboundLine {
		return NewError(413, "request_too_large", "The request is too large for Emacs")
	}
	ch := make(chan *Message, 1)
	c.addPending(id, ch)
	defer c.removePending(id)
	if err := c.write(data); err != nil {
		c.close()
		return ErrOffline
	}
	select {
	case resp := <-ch:
		if resp.Error != nil {
			return resp.Error
		}
		if result != nil && len(resp.Result) > 0 {
			if err := json.Unmarshal(resp.Result, result); err != nil {
				return &Error{Code: CodeInternal, Message: "bridge: bad result: " + err.Error()}
			}
		}
		return nil
	case <-c.closed:
		return ErrOffline
	case <-ctx.Done():
		if errors.Is(ctx.Err(), context.DeadlineExceeded) {
			return ErrTimeout
		}
		return ctx.Err()
	}
}

// Notify sends a notification to Emacs.
func (s *Server) Notify(method string, params any) error {
	c := s.current()
	if c == nil {
		return ErrOffline
	}
	return c.send(Message{Method: method}, params)
}

func call[R any](ctx context.Context, s *Server, method string, params any) (R, error) {
	var r R
	err := s.Call(ctx, method, params, &r)
	return r, err
}

// Prompt sends conversation.prompt.
func (s *Server) Prompt(ctx context.Context, p PromptParams) (PromptResult, error) {
	return call[PromptResult](ctx, s, MethodPrompt, p)
}

// Unqueue sends conversation.unqueue.
func (s *Server) Unqueue(ctx context.Context, p UnqueueParams) error {
	_, err := call[Empty](ctx, s, MethodUnqueue, p)
	return err
}

// Retry sends conversation.retry.
func (s *Server) Retry(ctx context.Context, p ConversationParams) error {
	_, err := call[Empty](ctx, s, MethodRetry, p)
	return err
}

// Action sends conversation.action.
func (s *Server) Action(ctx context.Context, p ActionParams) (ActionOutcome, error) {
	return call[ActionOutcome](ctx, s, MethodAction, p)
}

// Choose sends conversation.choose.
func (s *Server) Choose(ctx context.Context, p ChooseParams) error {
	_, err := call[Empty](ctx, s, MethodChoose, p)
	return err
}

// Answer sends conversation.answer.
func (s *Server) Answer(ctx context.Context, p AnswerParams) error {
	_, err := call[Empty](ctx, s, MethodAnswer, p)
	return err
}

// Attach sends conversation.attach.
func (s *Server) Attach(ctx context.Context, p AttachParams) (AttachResult, error) {
	return call[AttachResult](ctx, s, MethodAttach, p)
}

// Earlier sends conversation.earlier.
func (s *Server) Earlier(ctx context.Context, p ConversationParams) (EarlierResult, error) {
	return call[EarlierResult](ctx, s, MethodEarlier, p)
}

// Command sends node.command.
func (s *Server) Command(ctx context.Context, p CommandParams) (CommandOutcome, error) {
	return call[CommandOutcome](ctx, s, MethodCommand, p)
}

// Diff sends node.diff.
func (s *Server) Diff(ctx context.Context, p DiffParams) (DiffResult, error) {
	return call[DiffResult](ctx, s, MethodDiff, p)
}

// Ping sends ping.
func (s *Server) Ping(ctx context.Context) error {
	_, err := call[Empty](ctx, s, MethodPing, Empty{})
	return err
}

// Seen notifies Emacs that a reader caught up with a conversation.
func (s *Server) Seen(p ConversationParams) error {
	return s.Notify(MethodSeen, p)
}

// Resync asks Emacs for a fresh sync.
func (s *Server) Resync() error {
	return s.Notify(MethodResync, Empty{})
}

// conn is one Emacs connection.
type conn struct {
	s      *Server
	nc     net.Conn
	wmu    sync.Mutex
	bw     *bufio.Writer
	pmu    sync.Mutex
	pend   map[int64]chan *Message
	closed chan struct{}
	once   sync.Once
	hello  bool
	synced atomic.Bool
}

func (c *conn) close() {
	c.once.Do(func() {
		close(c.closed)
		c.nc.Close()
	})
}

func (c *conn) addPending(id int64, ch chan *Message) {
	c.pmu.Lock()
	c.pend[id] = ch
	c.pmu.Unlock()
}

func (c *conn) removePending(id int64) {
	c.pmu.Lock()
	delete(c.pend, id)
	c.pmu.Unlock()
}

func (c *conn) deliver(m *Message) {
	id, err := strconv.ParseInt(string(m.ID), 10, 64)
	if err != nil {
		c.s.log.Warn("bridge: response with unknown id", "id", string(m.ID))
		return
	}
	c.pmu.Lock()
	ch := c.pend[id]
	c.pmu.Unlock()
	if ch == nil {
		c.s.log.Info("bridge: late or unknown response", "id", id)
		return
	}
	ch <- m
}

func (c *conn) write(line []byte) error {
	c.wmu.Lock()
	defer c.wmu.Unlock()
	_ = c.nc.SetWriteDeadline(time.Now().Add(writeTimeout))
	if _, err := c.bw.Write(line); err != nil {
		return err
	}
	if err := c.bw.WriteByte('\n'); err != nil {
		return err
	}
	return c.bw.Flush()
}

// send writes m with params (requests, notifications) or result (responses) encoded from v.
func (c *conn) send(m Message, v any) error {
	m.JSONRPC = "2.0"
	if v != nil {
		raw, err := json.Marshal(v)
		if err != nil {
			return err
		}
		if m.Method != "" {
			m.Params = raw
		} else {
			m.Result = raw
		}
	}
	data, err := json.Marshal(m)
	if err != nil {
		return err
	}
	if len(data) > MaxOutboundLine {
		return NewError(413, "request_too_large", "The message is too large for Emacs")
	}
	if err := c.write(data); err != nil {
		c.close()
		return ErrOffline
	}
	return nil
}

func (c *conn) respond(id json.RawMessage, result any) {
	_ = c.send(Message{ID: id}, result)
}

func (c *conn) respondError(id json.RawMessage, e *Error) {
	_ = c.send(Message{ID: id, Error: e}, nil)
}

func (c *conn) resync() {
	_ = c.send(Message{Method: MethodResync}, Empty{})
}

func (s *Server) handle(nc net.Conn) {
	c := &conn{s: s, nc: nc, bw: bufio.NewWriterSize(nc, 64<<10), pend: map[int64]chan *Message{}, closed: make(chan struct{})}
	defer s.gone(c)
	defer c.close()
	_ = nc.SetReadDeadline(time.Now().Add(helloTimeout))
	r := bufio.NewReaderSize(nc, 64<<10)
	for {
		line, prefix, tooLong, err := readLine(r, MaxInboundLine)
		if err != nil {
			if !errors.Is(err, io.EOF) && !errors.Is(err, net.ErrClosed) {
				s.log.Info("bridge: connection ended", "err", err)
			}
			return
		}
		if tooLong {
			s.overlong(c, prefix)
			continue
		}
		if len(bytes.TrimSpace(line)) == 0 {
			continue
		}
		var m Message
		if err := json.Unmarshal(line, &m); err != nil {
			s.log.Warn("bridge: unparsable line dropped", "err", err, "bytes", len(line))
			id, method := envelopeHead(line)
			switch {
			case id != nil:
				c.respondError(id, &Error{Code: CodeParseError, Message: "parse error"})
			case method != "" && c.hello:
				c.resync()
			}
			continue
		}
		s.dispatch(c, &m)
	}
}

// overlong answers a dropped over-long line: 413 to a request, resync after a notification.
func (s *Server) overlong(c *conn, prefix []byte) {
	id, method := envelopeHead(prefix)
	s.log.Warn("bridge: over-long line dropped", "method", method)
	if id != nil {
		c.respondError(id, NewError(413, "request_too_large", "Message too large"))
		return
	}
	if c.hello {
		c.resync()
	}
}

func (s *Server) gone(c *conn) {
	s.applyMu.Lock()
	defer s.applyMu.Unlock()
	s.mu.Lock()
	active := s.active == c
	if active {
		s.active = nil
	}
	s.mu.Unlock()
	if active {
		s.log.Info("emacs disconnected")
		s.sink.Disconnected()
		if s.watcher != nil {
			s.watcher.Gone()
		}
	}
}

func isRequest(m *Message) bool {
	return len(m.ID) > 0 && string(m.ID) != "null" && m.Method != ""
}

func (s *Server) dispatch(c *conn, m *Message) {
	if m.Method == "" && len(m.ID) > 0 {
		c.deliver(m)
		return
	}
	if !c.hello {
		switch {
		case m.Method == MethodHello && isRequest(m):
			s.hello(c, m)
		case isRequest(m):
			c.respondError(m.ID, NewError(400, "hello_required", "Send hello first"))
		}
		return
	}
	if isRequest(m) {
		c.respondError(m.ID, &Error{Code: CodeMethodNotFound, Message: "method not found: " + m.Method})
		return
	}
	if m.Method == MethodBye {
		s.mu.Lock()
		active := s.active == c
		s.mu.Unlock()
		if active && s.watcher != nil {
			s.log.Info("emacs said bye")
			s.watcher.Bye()
		}
		return
	}
	s.apply(c, m)
}

func (s *Server) hello(c *conn, m *Message) {
	var p HelloParams
	if err := json.Unmarshal(m.Params, &p); err != nil {
		c.respondError(m.ID, &Error{Code: CodeInvalidParams, Message: "invalid hello params"})
		return
	}
	if p.Protocol != ProtocolVersion {
		c.respondError(m.ID, NewError(409, "protocol_mismatch",
			fmt.Sprintf("overlook-remoted speaks bridge protocol %d, not %d", ProtocolVersion, p.Protocol)))
		c.close()
		return
	}
	s.applyMu.Lock()
	s.mu.Lock()
	old := s.active
	s.active = c
	s.mu.Unlock()
	c.hello = true
	epoch := s.sink.Connected(p)
	if s.watcher != nil {
		s.watcher.Hello(p.PID)
	}
	s.applyMu.Unlock()
	if old != nil {
		old.close()
	}
	_ = c.nc.SetReadDeadline(time.Time{})
	s.log.Info("emacs connected", "epoch", p.Epoch, "emacs", p.Emacs, "pid", p.PID, "lost", p.Lost, "historyEpoch", epoch)
	c.respond(m.ID, HelloResult{Protocol: ProtocolVersion, Daemon: s.version, HistoryEpoch: epoch, MaxMessageBytes: MaxInboundLine})
}

func (s *Server) apply(c *conn, m *Message) {
	s.applyMu.Lock()
	defer s.applyMu.Unlock()
	s.mu.Lock()
	active := s.active == c
	s.mu.Unlock()
	if !active {
		return
	}
	if m.Method != MethodSync && !c.synced.Load() {
		s.log.Warn("bridge: message before sync dropped", "method", m.Method)
		return
	}
	p := NewParams(m.Method)
	if p == nil || m.Method == MethodHello {
		s.log.Warn("bridge: unknown notification dropped", "method", m.Method)
		return
	}
	if len(m.Params) > 0 {
		if err := json.Unmarshal(m.Params, p); err != nil {
			s.log.Warn("bridge: invalid params, asking for resync", "method", m.Method, "err", err)
			c.resync()
			return
		}
	}
	switch p := p.(type) {
	case *SyncParams:
		s.sink.Sync(*p)
		if !c.synced.Swap(true) {
			s.log.Info("emacs online")
		}
	case *DashboardSetParams:
		s.sink.SetDashboard(*p)
	case *ConversationSetParams:
		s.sink.SetConversation(*p)
	case *ConversationParams:
		if m.Method == MethodConversationRemove {
			s.sink.RemoveConversation(*p)
		}
	case *Event:
		s.sink.Event(*p)
	default:
		s.log.Warn("bridge: unexpected notification dropped", "method", m.Method)
	}
}

// readLine reads one \n-terminated line of at most max bytes; longer lines are discarded,
// keeping a prefix to recover the envelope's id.
func readLine(r *bufio.Reader, max int) (line, prefix []byte, tooLong bool, err error) {
	for {
		chunk, err := r.ReadSlice('\n')
		if !tooLong && len(line)+len(chunk) > max+1 {
			tooLong = true
			prefix = append(line, chunk...)
			if len(prefix) > recoverPrefix {
				prefix = prefix[:recoverPrefix]
			}
			line = nil
		} else if !tooLong {
			line = append(line, chunk...)
		}
		switch {
		case err == nil:
			return bytes.TrimRight(line, "\r\n"), prefix, tooLong, nil
		case errors.Is(err, bufio.ErrBufferFull):
			continue
		default:
			return nil, nil, false, err
		}
	}
}

// envelopeHead reads the top-level id and method of a possibly truncated JSON object.
func envelopeHead(data []byte) (id json.RawMessage, method string) {
	dec := json.NewDecoder(bytes.NewReader(data))
	if t, err := dec.Token(); err != nil || t != json.Delim('{') {
		return nil, ""
	}
	for dec.More() {
		t, err := dec.Token()
		if err != nil {
			return id, method
		}
		key, _ := t.(string)
		var v json.RawMessage
		if err := dec.Decode(&v); err != nil {
			return id, method
		}
		switch key {
		case "id":
			if len(v) > 0 && string(v) != "null" {
				id = v
			}
		case "method":
			_ = json.Unmarshal(v, &method)
		}
	}
	return id, method
}
