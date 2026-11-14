package main

import (
	"bufio"
	"bytes"
	"compress/gzip"
	"context"
	"crypto/ecdsa"
	"crypto/elliptic"
	"crypto/rand"
	"crypto/tls"
	"crypto/x509"
	"crypto/x509/pkix"
	"encoding/json"
	"encoding/pem"
	"io"
	"log/slog"
	"math/big"
	"net"
	"net/http"
	"os"
	"path/filepath"
	"strings"
	"sync"
	"testing"
	"time"

	"github.com/andybalholm/brotli"

	"github.com/guiyuanju/overlook/remote/internal/config"
	"github.com/guiyuanju/overlook/remote/internal/store"
	"github.com/guiyuanju/overlook/remote/web"
)

const (
	token = "e2e-token"
	conv  = "conversation-06f8144e9a2601385f737f5cb6540bf9f5df039c802afaa355a3296461e4b160"
)

func TestMain(m *testing.M) {
	assetsLevel = 4
	os.Exit(m.Run())
}

type running struct {
	t    *testing.T
	d    *daemon
	base string
	stop func()
}

func baseConfig(t *testing.T) config.Config {
	t.Helper()
	dir, err := os.MkdirTemp("", "ove2e")
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { os.RemoveAll(dir) })
	tokenFile := filepath.Join(dir, "token")
	if err := os.WriteFile(tokenFile, []byte(token+"\n"), 0o600); err != nil {
		t.Fatal(err)
	}
	return config.Config{
		Listen: []string{"127.0.0.1:0"}, TokenFile: tokenFile, Socket: filepath.Join(dir, "s", "bridge.sock"),
		StreamCompression: true, FakeEmacs: "../../testdata/fixtures", FakeSpeed: 20, FakeLiveDelay: -1,
	}
}

func launch(t *testing.T, cfg config.Config) *running {
	t.Helper()
	log := slog.New(slog.NewTextHandler(io.Discard, nil))
	if testing.Verbose() {
		log = slog.New(slog.NewTextHandler(os.Stderr, &slog.HandlerOptions{Level: slog.LevelDebug}))
	}
	d, err := newDaemon(cfg, log, web.FS)
	if err != nil {
		t.Fatal(err)
	}
	if err := d.listen(); err != nil {
		t.Fatal(err)
	}
	ctx, cancel := context.WithCancel(context.Background())
	done := make(chan error, 1)
	go func() { done <- d.serve(ctx) }()
	var once sync.Once
	r := &running{t: t, d: d, base: "http://" + d.listeners[0].addr, stop: func() {
		once.Do(func() {
			cancel()
			if err := <-done; err != nil {
				t.Errorf("serve: %v", err)
			}
		})
	}}
	t.Cleanup(r.stop)
	return r
}

// counter counts bytes read through it.
type counter struct {
	r io.Reader
	n int
}

func (c *counter) Read(p []byte) (int, error) {
	n, err := c.r.Read(p)
	c.n += n
	return n, err
}

type response struct {
	status  int
	header  http.Header
	body    []byte
	encoded int
}

func (r *running) get(path string, header ...string) response {
	r.t.Helper()
	req, _ := http.NewRequest("GET", r.base+path, nil)
	req.Header.Set("Authorization", "Bearer "+token)
	for i := 0; i+1 < len(header); i += 2 {
		req.Header.Set(header[i], header[i+1])
	}
	resp, err := (&http.Client{Transport: &http.Transport{DisableCompression: true}}).Do(req)
	if err != nil {
		r.t.Fatal(err)
	}
	defer resp.Body.Close()
	raw, _ := io.ReadAll(resp.Body)
	body := raw
	switch resp.Header.Get("Content-Encoding") {
	case "br":
		body, _ = io.ReadAll(brotli.NewReader(bytes.NewReader(raw)))
	case "gzip":
		gz, _ := gzip.NewReader(bytes.NewReader(raw))
		body, _ = io.ReadAll(gz)
	}
	return response{resp.StatusCode, resp.Header, body, len(raw)}
}

func (r *running) waitOnline() {
	r.t.Helper()
	deadline := time.Now().Add(5 * time.Second)
	for time.Now().Before(deadline) {
		if res := r.get("/overlook/healthz"); strings.Contains(string(res.body), `"online"`) {
			if snap := r.get("/overlook/api/conversations/" + conv); strings.Contains(string(snap.body), `"type":"end"`) {
				return
			}
		}
		time.Sleep(20 * time.Millisecond)
	}
	r.t.Fatal("fake Emacs never came online")
}

type sse struct {
	id, event string
	data      []byte
}

// TestEndToEnd drives the daemon with the fake Emacs over the real socket and reads the real stream.
func TestEndToEnd(t *testing.T) {
	r := launch(t, baseConfig(t))
	r.waitOnline()

	page := r.get("/overlook/", "Accept-Encoding", "br")
	if page.status != 200 || !strings.Contains(string(page.body), `<script type="importmap">`) || page.encoded >= len(page.body) {
		t.Fatalf("page %d, %d of %d bytes", page.status, page.encoded, len(page.body))
	}
	if again := r.get("/overlook/", "If-None-Match", page.header.Get("ETag")); again.status != 304 || again.encoded != 0 {
		t.Fatalf("page revalidation %d", again.status)
	}

	dash := r.get("/overlook/api/dashboard", "Accept-Encoding", "br")
	var dashboard store.Dashboard
	if err := json.Unmarshal(dash.body, &dashboard); err != nil || dashboard.Emacs != store.EmacsOnline {
		t.Fatalf("dashboard %s", dash.body)
	}
	t.Logf("dashboard snapshot: %d bytes, %d brotli", len(dash.body), dash.encoded)
	if dash.encoded*2 > len(dash.body) {
		t.Errorf("dashboard compressed poorly: %d of %d", dash.encoded, len(dash.body))
	}
	if again := r.get("/overlook/api/dashboard", "If-None-Match", dash.header.Get("ETag")); again.status != 304 || again.encoded != 0 {
		t.Fatalf("dashboard revalidation %d", again.status)
	}

	snapRes := r.get("/overlook/api/conversations/"+conv, "Accept-Encoding", "gzip")
	var snap store.ConversationSnapshot
	if err := json.Unmarshal(snapRes.body, &snap); err != nil || len(snap.Items) == 0 {
		t.Fatalf("snapshot %s", snapRes.body)
	}
	var image string
	var reply int64
	for _, it := range snap.Items {
		if len(it.Images) > 0 {
			image = it.Images[0]
		}
		if it.Type == "text" {
			reply = it.Item
		}
	}
	if image == "" {
		t.Fatal("no images resolved from the fixtures")
	}
	if img := r.get("/overlook/api/images/" + image); img.status != 200 || store.SniffImage(img.body) != "image/png" ||
		!strings.Contains(img.header.Get("Cache-Control"), "immutable") {
		t.Fatalf("image %d %v", img.status, img.header)
	}

	req, _ := http.NewRequest("GET", r.base+"/overlook/api/stream?dashboard="+dashboard.Known+"&conversation="+conv+
		"&after="+itoa(snap.Seq)+"&known="+snap.Known+"&epoch="+snap.Epoch, nil)
	req.Header.Set("Authorization", "Bearer "+token)
	req.Header.Set("Accept-Encoding", "gzip")
	resp, err := (&http.Client{Transport: &http.Transport{DisableCompression: true}}).Do(req)
	if err != nil {
		t.Fatal(err)
	}
	defer resp.Body.Close()
	if resp.Header.Get("Content-Encoding") != "gzip" || resp.Header.Get("Overlook-Protocol") != "3" {
		t.Fatalf("stream headers %v", resp.Header)
	}
	wire := &counter{r: resp.Body}
	gz, err := gzip.NewReader(wire)
	if err != nil {
		t.Fatal(err)
	}
	plain := &counter{r: gz}
	events := make(chan sse, 64)
	go func() {
		defer close(events)
		br := bufio.NewReader(plain)
		var ev sse
		for {
			line, err := br.ReadString('\n')
			if err != nil {
				return
			}
			line = strings.TrimSuffix(line, "\n")
			switch {
			case line == "" && ev.event != "":
				events <- ev
				ev = sse{}
			case strings.HasPrefix(line, "id: "):
				ev.id = line[4:]
			case strings.HasPrefix(line, "event: "):
				ev.event = line[7:]
			case strings.HasPrefix(line, "data: "):
				ev.data = []byte(line[6:])
			}
		}
	}()
	next := func(timeout time.Duration) (sse, bool) {
		select {
		case ev, ok := <-events:
			return ev, ok
		case <-time.After(timeout):
			return sse{}, false
		}
	}
	if ev, _ := next(2 * time.Second); ev.event != "hello" {
		t.Fatalf("first event %+v", ev)
	}
	if ev, ok := next(300 * time.Millisecond); ok {
		t.Fatalf("unchanged cursors produced %s %s", ev.event, ev.data)
	}

	r.d.fake.PlayLive()
	var text strings.Builder
	var sawSame, sawState, sawEnd bool
	var convEvents, lastID string
	deadline := time.After(10 * time.Second)
	for !sawEnd {
		var ev sse
		select {
		case ev = <-events:
		case <-deadline:
			t.Fatalf("live replay incomplete; text so far %q", text.String())
		}
		switch ev.event {
		case "dashboard":
			var d store.DashboardDelta
			_ = json.Unmarshal(ev.data, &d)
			for _, s := range d.Sections {
				sawSame = sawSame || s.Same != ""
			}
		case "conversation":
			var d store.ConversationDelta
			if err := json.Unmarshal(ev.data, &d); err != nil {
				t.Fatal(err)
			}
			if strings.Contains(string(ev.data), `"reset":true`) {
				t.Fatalf("unexpected reset %s", ev.data)
			}
			sawState = sawState || d.Conversation != nil
			for _, it := range d.Items {
				if it.Type == "text" && it.Item == reply {
					if it.Offset == 0 {
						t.Fatalf("reply chunk without offset: %+v", it)
					}
					text.WriteString(it.Text)
				}
				if it.Type == "tool" && it.Status == "completed" && it.Title == "Run go vet ./..." {
					sawEnd = true
				}
			}
			convEvents += "."
			lastID = ev.id
		}
	}
	if !strings.HasSuffix(text.String(), "and the test passes. 🎉") || !sawSame || !sawState {
		t.Fatalf("text %q same=%v state=%v", text.String(), sawSame, sawState)
	}
	t.Logf("stream: %d conversation events, %d bytes of events, %d bytes on the wire", len(convEvents), plain.n, wire.n)
	if wire.n >= plain.n {
		t.Errorf("gzip stream did not save bytes: %d wire for %d plain", wire.n, plain.n)
	}

	resumed := r.get("/overlook/api/conversations/"+conv, "If-None-Match", `"`+cursorETag(lastID)+`"`)
	if resumed.status != 304 {
		t.Errorf("snapshot at the stream cursor not 304: %d (%s)", resumed.status, cursorETag(lastID))
	}

	prompt, _ := http.NewRequest("POST", r.base+"/overlook/api/conversations/"+conv+"/prompts", strings.NewReader(`{"text":"next"}`))
	prompt.Header.Set("Authorization", "Bearer "+token)
	prompt.Header.Set("Idempotency-Key", "e2e-1")
	presp, err := http.DefaultClient.Do(prompt)
	if err != nil {
		t.Fatal(err)
	}
	pbody, _ := io.ReadAll(presp.Body)
	presp.Body.Close()
	if presp.StatusCode != 200 || string(pbody) != `{"delivery":"queued","queueId":"queued-3"}` {
		t.Fatalf("prompt %d %s", presp.StatusCode, pbody)
	}
}

// cursorETag turns a stream event id into the snapshot ETag of the same state.
func cursorETag(id string) string {
	var epoch, after, known string
	for _, kv := range strings.Split(id, "&") {
		k, v, _ := strings.Cut(kv, "=")
		switch k {
		case "epoch":
			epoch = v
		case "after":
			after = v
		case "known":
			known = v
		}
	}
	return epoch + "." + after + "." + known
}

func itoa(n int64) string {
	b, _ := json.Marshal(n)
	return string(b)
}

func TestAutoCloseNonLoopback(t *testing.T) {
	cfg := baseConfig(t)
	cfg.FakeEmacs = ""
	cfg.Listen = []string{"127.0.0.1:0", "0.0.0.0:0"}
	cfg.AutoClose = 100 * time.Millisecond
	r := launch(t, cfg)
	exposed := r.d.listeners[1]
	if exposed.loopback || !r.d.listeners[0].loopback {
		t.Fatalf("loopback detection: %+v %+v", r.d.listeners[0], exposed)
	}
	_, port, _ := net.SplitHostPort(exposed.addr)
	time.Sleep(400 * time.Millisecond)
	if c, err := net.DialTimeout("tcp", "127.0.0.1:"+port, time.Second); err == nil {
		c.Close()
		t.Fatal("non-loopback listener still open")
	}
	if res := r.get("/overlook/healthz"); res.status != 200 {
		t.Fatalf("loopback listener closed too: %d", res.status)
	}
}

func TestTLSServesHTTP2(t *testing.T) {
	cfg := baseConfig(t)
	cfg.FakeEmacs = ""
	cfg.Listen = nil
	cfg.ListenTLS = []string{"127.0.0.1:0"}
	cfg.TLSCert, cfg.TLSKey = selfSigned(t, filepath.Dir(cfg.TokenFile))
	r := launch(t, cfg)
	client := &http.Client{Transport: &http.Transport{
		TLSClientConfig:   &tls.Config{InsecureSkipVerify: true},
		ForceAttemptHTTP2: true,
	}}
	resp, err := client.Get("https://" + r.d.listeners[0].addr + "/overlook/healthz")
	if err != nil {
		t.Fatal(err)
	}
	resp.Body.Close()
	if resp.ProtoMajor != 2 || resp.StatusCode != 200 {
		t.Fatalf("got %s %d", resp.Proto, resp.StatusCode)
	}
}

func selfSigned(t *testing.T, dir string) (certFile, keyFile string) {
	t.Helper()
	key, _ := ecdsa.GenerateKey(elliptic.P256(), rand.Reader)
	tmpl := &x509.Certificate{
		SerialNumber: big.NewInt(1), Subject: pkix.Name{CommonName: "localhost"},
		NotBefore: time.Now().Add(-time.Hour), NotAfter: time.Now().Add(time.Hour),
		IPAddresses: []net.IP{net.ParseIP("127.0.0.1")},
	}
	der, err := x509.CreateCertificate(rand.Reader, tmpl, tmpl, &key.PublicKey, key)
	if err != nil {
		t.Fatal(err)
	}
	kder, _ := x509.MarshalECPrivateKey(key)
	certFile, keyFile = filepath.Join(dir, "cert.pem"), filepath.Join(dir, "key.pem")
	_ = os.WriteFile(certFile, pem.EncodeToMemory(&pem.Block{Type: "CERTIFICATE", Bytes: der}), 0o600)
	_ = os.WriteFile(keyFile, pem.EncodeToMemory(&pem.Block{Type: "EC PRIVATE KEY", Bytes: kder}), 0o600)
	return certFile, keyFile
}
