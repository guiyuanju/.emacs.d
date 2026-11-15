// Package admin is the daemon's control socket for local tools such as the menu bar app.
//
// Each line a client writes is one JSON request; each line the daemon writes is one JSON response.
// Socket permissions (0600 in a 0700 directory) are the authentication.
package admin

import (
	"bufio"
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"log/slog"
	"net"
	"os"
	"path/filepath"
	"sync"
	"time"
)

// Request operations.
const (
	OpStatus   = "status"
	OpWatch    = "watch"
	OpSetAwake = "set-awake"
)

// Request is one line from a client.
type Request struct {
	Op string `json:"op"`
	// On is set-awake's new value.
	On *bool `json:"on,omitempty"`
}

// Response is one line to a client: a status or an error.
type Response struct {
	Status *Status `json:"status,omitempty"`
	Error  string  `json:"error,omitempty"`
}

// Status describes the running daemon.
type Status struct {
	Daemon  string    `json:"daemon"`
	Started time.Time `json:"started"`
	// Uptime is in seconds; watch does not push for it alone.
	Uptime    float64    `json:"uptime"`
	Emacs     string     `json:"emacs"`
	Streams   int        `json:"streams"`
	Listeners []Listener `json:"listeners"`
	// Awake is the keep-awake setting; AwakeHeld whether caffeinate runs now.
	Awake     bool `json:"awake"`
	AwakeHeld bool `json:"awakeHeld"`
	// Scheme, Host and Port make the page URL a phone opens; Host is "" when no address fits.
	Scheme string `json:"scheme"`
	Host   string `json:"host"`
	Port   int    `json:"port"`
}

// Listener is an HTTP listener of the daemon.
type Listener struct {
	Addr     string `json:"addr"`
	TLS      bool   `json:"tls,omitempty"`
	Loopback bool   `json:"loopback,omitempty"`
}

func (s Status) same(o Status) bool {
	s.Uptime, o.Uptime = 0, 0
	a, _ := json.Marshal(s)
	b, _ := json.Marshal(o)
	return string(a) == string(b)
}

// Daemon is what the socket reports on and controls.
type Daemon interface {
	Status() Status
	SetAwake(on bool) error
}

// recheck is how often watchers recompute the status without being told of a change, catching address changes.
var recheck = 5 * time.Second

// Server serves the admin socket.
type Server struct {
	path string
	d    Daemon
	log  *slog.Logger

	mu      sync.Mutex
	ln      net.Listener
	changed chan struct{}
}

// NewServer returns a server for the socket at path.
func NewServer(path string, d Daemon, log *slog.Logger) *Server {
	if log == nil {
		log = slog.New(slog.DiscardHandler)
	}
	return &Server{path: path, d: d, log: log, changed: make(chan struct{})}
}

// Changed wakes the watchers to compare the status with what they sent; a nil Server ignores it.
func (s *Server) Changed() {
	if s == nil {
		return
	}
	s.mu.Lock()
	close(s.changed)
	s.changed = make(chan struct{})
	s.mu.Unlock()
}

func (s *Server) wake() <-chan struct{} {
	s.mu.Lock()
	defer s.mu.Unlock()
	return s.changed
}

// Listen creates the 0700 directory and the 0600 socket, removing a stale socket file.
func (s *Server) Listen() error {
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
			return fmt.Errorf("admin: %s is in use by another daemon", s.path)
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
	s.mu.Lock()
	s.ln = ln
	s.mu.Unlock()
	return nil
}

// Serve accepts clients until ctx ends, then closes them and removes the socket.
func (s *Server) Serve(ctx context.Context) error {
	s.mu.Lock()
	ln := s.ln
	s.mu.Unlock()
	if ln == nil {
		return errors.New("admin: Serve before Listen")
	}
	var wg sync.WaitGroup
	conns := map[net.Conn]struct{}{}
	var cmu sync.Mutex
	go func() {
		<-ctx.Done()
		ln.Close()
		cmu.Lock()
		for c := range conns {
			c.Close()
		}
		cmu.Unlock()
	}()
	defer func() {
		wg.Wait()
		_ = os.Remove(s.path)
	}()
	for {
		c, err := ln.Accept()
		if err != nil {
			if ctx.Err() != nil {
				return nil
			}
			return err
		}
		cmu.Lock()
		conns[c] = struct{}{}
		cmu.Unlock()
		wg.Add(1)
		go func() {
			defer wg.Done()
			s.handle(ctx, c)
			cmu.Lock()
			delete(conns, c)
			cmu.Unlock()
			c.Close()
		}()
	}
}

func (s *Server) handle(ctx context.Context, c net.Conn) {
	cctx, cancel := context.WithCancel(ctx)
	defer cancel()
	var wmu sync.Mutex
	enc := json.NewEncoder(c)
	send := func(r Response) error {
		wmu.Lock()
		defer wmu.Unlock()
		_ = c.SetWriteDeadline(time.Now().Add(5 * time.Second))
		return enc.Encode(r)
	}
	var watching sync.WaitGroup
	defer watching.Wait()
	sc := bufio.NewScanner(c)
	for sc.Scan() {
		var req Request
		if err := json.Unmarshal(sc.Bytes(), &req); err != nil {
			_ = send(Response{Error: "bad request: " + err.Error()})
			continue
		}
		switch req.Op {
		case OpStatus:
			st := s.d.Status()
			_ = send(Response{Status: &st})
		case OpSetAwake:
			if req.On == nil {
				_ = send(Response{Error: `set-awake needs "on"`})
				continue
			}
			if err := s.d.SetAwake(*req.On); err != nil {
				_ = send(Response{Error: err.Error()})
				continue
			}
			s.log.Info("admin: keep awake set", "on", *req.On)
			st := s.d.Status()
			_ = send(Response{Status: &st})
		case OpWatch:
			watching.Add(1)
			go func() {
				defer watching.Done()
				defer cancel()
				s.watch(cctx, send)
			}()
		default:
			_ = send(Response{Error: fmt.Sprintf("unknown op %q", req.Op)})
		}
	}
	cancel()
}

// watch sends the status now and again whenever it differs from the last one sent.
func (s *Server) watch(ctx context.Context, send func(Response) error) {
	tick := time.NewTicker(recheck)
	defer tick.Stop()
	var last *Status
	for {
		wake := s.wake()
		st := s.d.Status()
		if last == nil || !st.same(*last) {
			if send(Response{Status: &st}) != nil {
				return
			}
			last = &st
		}
		select {
		case <-ctx.Done():
			return
		case <-wake:
		case <-tick.C:
		}
	}
}

// Client talks to an admin socket.
type Client struct {
	c   net.Conn
	dec *json.Decoder
}

// Dial connects to the socket at path.
func Dial(path string) (*Client, error) {
	c, err := net.DialTimeout("unix", path, 2*time.Second)
	if err != nil {
		return nil, err
	}
	return &Client{c: c, dec: json.NewDecoder(c)}, nil
}

// Close closes the connection.
func (c *Client) Close() error { return c.c.Close() }

func (c *Client) send(r Request) error {
	_ = c.c.SetWriteDeadline(time.Now().Add(5 * time.Second))
	return json.NewEncoder(c.c).Encode(r)
}

// Next reads the next status; a Response error becomes an error.
func (c *Client) Next() (Status, error) {
	var r Response
	if err := c.dec.Decode(&r); err != nil {
		return Status{}, err
	}
	if r.Error != "" {
		return Status{}, errors.New(r.Error)
	}
	if r.Status == nil {
		return Status{}, errors.New("admin: response without status")
	}
	return *r.Status, nil
}

func (c *Client) call(r Request) (Status, error) {
	if err := c.send(r); err != nil {
		return Status{}, err
	}
	_ = c.c.SetReadDeadline(time.Now().Add(5 * time.Second))
	defer c.c.SetReadDeadline(time.Time{})
	return c.Next()
}

// Status asks for the status.
func (c *Client) Status() (Status, error) { return c.call(Request{Op: OpStatus}) }

// SetAwake turns keeping awake on or off and returns the new status.
func (c *Client) SetAwake(on bool) (Status, error) { return c.call(Request{Op: OpSetAwake, On: &on}) }

// Watch asks for status pushes; read them with Next.
func (c *Client) Watch() error { return c.send(Request{Op: OpWatch}) }

// Do dials path, runs fn and closes the connection.
func Do(path string, fn func(*Client) (Status, error)) (Status, error) {
	c, err := Dial(path)
	if err != nil {
		return Status{}, err
	}
	defer c.Close()
	return fn(c)
}

// Watch calls fn with each status the daemon at path pushes until ctx ends or the connection fails.
func Watch(ctx context.Context, path string, fn func(Status)) error {
	c, err := Dial(path)
	if err != nil {
		return err
	}
	defer c.Close()
	stop := context.AfterFunc(ctx, func() { c.Close() })
	defer stop()
	if err := c.Watch(); err != nil {
		return err
	}
	for {
		st, err := c.Next()
		if err != nil {
			if ctx.Err() != nil {
				return ctx.Err()
			}
			return err
		}
		fn(st)
	}
}
