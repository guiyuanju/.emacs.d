// Command overlook-remoted serves the overlook remote page and API, with Emacs connected over a unix socket.
package main

import (
	"context"
	"crypto/tls"
	"errors"
	"flag"
	"fmt"
	"io/fs"
	"log/slog"
	"net"
	"net/http"
	"os"
	"os/signal"
	"path/filepath"
	"strconv"
	"sync"
	"syscall"
	"time"

	"github.com/guiyuanju/overlook/remote/internal/admin"
	"github.com/guiyuanju/overlook/remote/internal/api"
	"github.com/guiyuanju/overlook/remote/internal/assets"
	"github.com/guiyuanju/overlook/remote/internal/auth"
	"github.com/guiyuanju/overlook/remote/internal/awake"
	"github.com/guiyuanju/overlook/remote/internal/bridge"
	"github.com/guiyuanju/overlook/remote/internal/config"
	"github.com/guiyuanju/overlook/remote/internal/fakeemacs"
	"github.com/guiyuanju/overlook/remote/internal/launchd"
	"github.com/guiyuanju/overlook/remote/internal/netaddr"
	"github.com/guiyuanju/overlook/remote/internal/settings"
	"github.com/guiyuanju/overlook/remote/internal/state"
	"github.com/guiyuanju/overlook/remote/internal/store"
	"github.com/guiyuanju/overlook/remote/internal/stream"
	"github.com/guiyuanju/overlook/remote/internal/usage"
	"github.com/guiyuanju/overlook/remote/web"
)

// version is set with -ldflags "-X main.version=…".
var version = "dev"

var (
	_ api.Emacs     = (*bridge.Server)(nil)
	_ stream.Source = (*store.Store)(nil)
	_ admin.Daemon  = (*daemon)(nil)
)

// assetsLevel is the brotli quality of precompressed page files; tests lower it.
var assetsLevel = 11

// shutdownGrace bounds graceful shutdown of the HTTP servers.
const shutdownGrace = 5 * time.Second

// saveInterval is how often changed state is written to the state file; tests shorten it.
var saveInterval = 30 * time.Second

func main() {
	cfg, err := config.Parse(os.Args[1:], os.Stderr)
	if errors.Is(err, flag.ErrHelp) {
		return
	}
	if err != nil {
		fmt.Fprintln(os.Stderr, "overlook-remoted:", err)
		os.Exit(2)
	}
	level := slog.LevelInfo
	if cfg.Debug {
		level = slog.LevelDebug
	}
	log := slog.New(slog.NewTextHandler(os.Stderr, &slog.HandlerOptions{Level: level}))
	ctx, stop := signal.NotifyContext(context.Background(), os.Interrupt, syscall.SIGTERM)
	defer stop()
	if err := run(ctx, cfg, log); err != nil {
		log.Error("exit", "err", err)
		os.Exit(1)
	}
}

func run(ctx context.Context, cfg config.Config, log *slog.Logger) error {
	started := time.Now()
	log.Info("starting", "version", version, "listen", cfg.Listen, "listen-tls", cfg.ListenTLS, "socket", cfg.Socket,
		"web-dir", cfg.WebDir, "state-file", cfg.StateFile, "admin-socket", cfg.AdminSocket)
	d, err := newDaemon(cfg, log, web.FS)
	if err != nil {
		return err
	}
	if err := d.listen(); err != nil {
		d.close()
		return err
	}
	log.Info("ready", "after", time.Since(started).Round(time.Millisecond))
	if d.fake != nil {
		usr1 := make(chan os.Signal, 1)
		signal.Notify(usr1, syscall.SIGUSR1)
		defer signal.Stop(usr1)
		go func() {
			for range usr1 {
				d.fake.PlayLive()
			}
		}()
	}
	return d.serve(ctx)
}

// daemon is the wired daemon: store, hub, bridge, API and listeners.
type daemon struct {
	cfg       config.Config
	log       *slog.Logger
	store     *store.Store
	hub       *stream.Hub
	bridge    *bridge.Server
	receipts  *api.Receipts
	handler   http.Handler
	listeners []*listener
	fake      *fakeemacs.Fake
	confirmer *api.Confirmer
	admin     *admin.Server
	awake     *awake.Keeper
	started   time.Time
	usage     *usage.Ledger

	// settingsMu guards settings, the user settings kept in cfg.SettingsFile.
	settingsMu sync.Mutex
	settings   settings.Settings

	// saveMu serializes state file writes; saved holds the store and receipt versions last written.
	saveMu sync.Mutex
	saved  [2]uint64
}

type listener struct {
	addr     string
	tls      bool
	loopback bool
	ln       net.Listener
	srv      *http.Server
}

func newDaemon(cfg config.Config, log *slog.Logger, webFS fs.FS) (*daemon, error) {
	tokens, err := auth.NewTokens(cfg.TokenFile)
	if err != nil {
		return nil, fmt.Errorf("token file: %w", err)
	}
	page, err := assets.Open(webFS, assets.Options{Level: assetsLevel, CacheDir: cfg.CacheDir, Dir: cfg.WebDir, Log: log})
	if err != nil {
		return nil, err
	}
	var storeDir string
	if cfg.StateFile != "" {
		storeDir = filepath.Join(filepath.Dir(cfg.StateFile), "media")
		if err := os.MkdirAll(storeDir, 0o700); err != nil {
			return nil, err
		}
	}
	d := &daemon{cfg: cfg, log: log, store: store.New(store.Options{Dir: storeDir}), receipts: &api.Receipts{}, started: time.Now()}
	d.restore()
	if cfg.FakeEmacs == "" && cfg.StateFile != "" {
		home, _ := os.UserHomeDir()
		d.usage, err = usage.Open(usage.Options{Path: filepath.Join(filepath.Dir(cfg.StateFile), "usage.sqlite"), LegacyPath: filepath.Join(filepath.Dir(cfg.StateFile), "usage.json"), Sources: usage.DefaultSources(home), Project: d.store.UsageProject})
		if err != nil {
			log.Warn("consumption ledger unavailable", "err", err)
			d.usage = usage.Unavailable("Consumption history could not be loaded. The original ledger has been preserved.")
		}
	}
	d.settings = settings.Default
	if cfg.SettingsFile != "" {
		if d.settings, err = settings.Load(cfg.SettingsFile); err != nil {
			log.Warn("ignoring the settings file", "file", cfg.SettingsFile, "err", err)
		}
	}
	if cfg.AdminSocket != "" {
		d.admin = admin.NewServer(cfg.AdminSocket, d, log)
	}
	d.awake = awake.New(cfg.Caffeinate, log, d.admin.Changed)
	d.bridge = bridge.NewServer(cfg.Socket, version, d.store, log)
	opts := stream.DefaultOptions
	opts.Compress = cfg.StreamCompression
	opts.Earlier = api.EarlierFunc(d.bridge, d.store)
	opts.Counted = d.admin.Changed
	d.hub = stream.NewHub(d.store, opts)
	d.store.OnChange(func(c store.Change) {
		d.hub.Notify(c)
		if c.Epoch {
			d.receipts.Clear()
		}
		if c.Status || c.Epoch {
			d.admin.Changed()
		}
	})
	deny := http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		api.WriteProblem(w, api.NewProblem(http.StatusUnauthorized, api.CodeUnauthorized, "Open the page from its launch link"))
	})
	d.handler = api.New(api.Deps{
		Usage: d.usage, Store: d.store, Emacs: d.bridge, Hub: d.hub, Auth: auth.Require(tokens, deny),
		Assets: page, Log: log, Receipts: d.receipts, Confirmer: d.confirmer, Version: version,
	}).Handler()
	if cfg.FakeEmacs != "" {
		fx, err := fakeemacs.Load(cfg.FakeEmacs)
		if err != nil {
			d.close()
			return nil, fmt.Errorf("fake emacs: %w", err)
		}
		d.fake = &fakeemacs.Fake{Socket: cfg.Socket, Fixtures: fx, Speed: cfg.FakeSpeed, LiveDelay: cfg.FakeLiveDelay, Resume: cfg.FakeResume}
	}
	return d, nil
}

// restore loads the state file, if any; the next hello keeps it only for the same Emacs epoch.
func (d *daemon) restore() {
	d.confirmer = api.NewConfirmer()
	if d.cfg.StateFile == "" {
		return
	}
	f, err := state.Load(d.cfg.StateFile)
	switch {
	case errors.Is(err, fs.ErrNotExist):
		d.store.Restore(nil)
		return
	case err != nil:
		d.log.Warn("ignoring the state file", "file", d.cfg.StateFile, "err", err)
		d.store.Restore(nil)
		return
	}
	d.store.Restore(f.Store)
	d.receipts.Restore(f.Receipts)
	d.confirmer = api.ConfirmerWithSecret(f.Secret)
	d.saved = [2]uint64{d.store.Version(), d.receipts.Version()}
	d.log.Info("state restored", "file", d.cfg.StateFile, "saved", f.SavedAt.Format(time.RFC3339), "by", f.Daemon,
		"conversations", len(f.Store.Convs), "epoch", d.store.Epoch())
}

// save writes the state file when anything changed since the last write, or always when force is set.
func (d *daemon) save(force bool) {
	if d.cfg.StateFile == "" {
		return
	}
	d.saveMu.Lock()
	defer d.saveMu.Unlock()
	versions := [2]uint64{d.store.Version(), d.receipts.Version()}
	if !force && versions == d.saved {
		return
	}
	started := time.Now()
	f := &state.File{SavedAt: started, Daemon: version, Secret: d.confirmer.Secret(), Store: d.store.Save(), Receipts: d.receipts.Save()}
	if err := state.Write(d.cfg.StateFile, f); err != nil {
		d.log.Error("writing the state file", "file", d.cfg.StateFile, "err", err)
		return
	}
	d.saved = versions
	d.log.Debug("state saved", "file", d.cfg.StateFile, "took", time.Since(started))
}

func loopback(addr string) bool {
	host, _, err := net.SplitHostPort(addr)
	if err != nil {
		return false
	}
	if host == "localhost" {
		return true
	}
	ip := net.ParseIP(host)
	return ip != nil && ip.IsLoopback()
}

// listen binds the bridge socket and every HTTP listener, so errors surface before serving.
func (d *daemon) listen() error {
	if err := d.bridge.Listen(); err != nil {
		return err
	}
	if d.admin != nil {
		if err := d.admin.Listen(); err != nil {
			return err
		}
	}
	var tlsConfig *tls.Config
	if len(d.cfg.ListenTLS) > 0 {
		certs, err := newCertReloader(d.cfg.TLSCert, d.cfg.TLSKey)
		if err != nil {
			return err
		}
		tlsConfig = &tls.Config{MinVersion: tls.VersionTLS12, GetCertificate: certs.get}
	}
	add := func(addr string, useTLS bool) error {
		if name, ok := launchd.Name(addr); ok {
			lns, err := launchd.Listeners(name)
			if err != nil {
				return err
			}
			for _, ln := range lns {
				d.addListener(ln, useTLS, tlsConfig)
			}
			return nil
		}
		ln, err := net.Listen("tcp", addr)
		if err != nil {
			return err
		}
		d.addListener(ln, useTLS, tlsConfig)
		return nil
	}
	for _, a := range d.cfg.Listen {
		if err := add(a, false); err != nil {
			return err
		}
	}
	for _, a := range d.cfg.ListenTLS {
		if err := add(a, true); err != nil {
			return err
		}
	}
	return nil
}

func (d *daemon) addListener(ln net.Listener, useTLS bool, tlsConfig *tls.Config) {
	srv := &http.Server{
		Handler:           d.handler,
		ReadHeaderTimeout: 10 * time.Second,
		IdleTimeout:       2 * time.Minute,
		MaxHeaderBytes:    64 << 10,
		ErrorLog:          slog.NewLogLogger(d.log.Handler(), slog.LevelDebug),
	}
	if useTLS {
		srv.TLSConfig = tlsConfig.Clone()
	}
	addr := ln.Addr().String()
	d.listeners = append(d.listeners, &listener{addr: addr, tls: useTLS, loopback: loopback(addr), ln: ln, srv: srv})
}

// serve runs everything until ctx ends, then shuts down gracefully.
func (d *daemon) serve(ctx context.Context) error {
	defer d.close()
	bctx, bcancel := context.WithCancel(context.Background())
	var wg sync.WaitGroup
	if d.usage != nil {
		wg.Add(1)
		go func() { defer wg.Done(); d.usage.Run(bctx) }()
	}
	errs := make(chan error, len(d.listeners)+3)
	wg.Add(1)
	go func() {
		defer wg.Done()
		if err := d.bridge.Serve(bctx); err != nil {
			errs <- err
		}
	}()
	if d.admin != nil {
		wg.Add(1)
		go func() {
			defer wg.Done()
			if err := d.admin.Serve(bctx); err != nil {
				errs <- err
			}
		}()
	}
	if d.settings.Awake {
		if err := d.awake.Set(true); errors.Is(err, awake.ErrUnavailable) {
			d.log.Debug("not keeping the Mac awake: no -caffeinate")
		}
	}
	for _, l := range d.listeners {
		scheme := "http"
		if l.tls {
			scheme = "https"
		}
		d.log.Info("listening", "url", scheme+"://"+l.addr+"/overlook/", "loopback", l.loopback)
		wg.Add(1)
		go func() {
			defer wg.Done()
			var err error
			if l.tls {
				err = l.srv.ServeTLS(l.ln, "", "")
			} else {
				err = l.srv.Serve(l.ln)
			}
			if err != nil && !errors.Is(err, http.ErrServerClosed) {
				errs <- err
			}
		}()
		if d.cfg.AutoClose > 0 && !l.loopback {
			timer := time.AfterFunc(d.cfg.AutoClose, func() {
				d.log.Info("auto-close", "addr", l.addr, "after", d.cfg.AutoClose)
				_ = l.srv.Close()
			})
			defer timer.Stop()
		}
	}
	if d.cfg.StateFile != "" {
		wg.Add(1)
		go func() {
			defer wg.Done()
			tick := time.NewTicker(saveInterval)
			defer tick.Stop()
			for {
				select {
				case <-bctx.Done():
					return
				case <-tick.C:
					d.save(false)
				}
			}
		}()
	}
	fctx, fcancel := context.WithCancel(context.Background())
	if d.fake != nil {
		wg.Add(1)
		go func() {
			defer wg.Done()
			if err := d.fake.Run(fctx); err != nil {
				d.log.Warn("fake emacs stopped", "err", err)
			}
		}()
	}
	var err error
	select {
	case <-ctx.Done():
	case err = <-errs:
	}
	d.log.Info("shutting down")
	fcancel()
	d.hub.Close()
	sctx, scancel := context.WithTimeout(context.Background(), shutdownGrace)
	defer scancel()
	for _, l := range d.listeners {
		if serr := l.srv.Shutdown(sctx); serr != nil {
			_ = l.srv.Close()
		}
	}
	bcancel()
	wg.Wait()
	d.awake.Close()
	// Emacs is disconnected now, so nothing changes after this write.
	d.save(true)
	return err
}

func (d *daemon) close() {
	if d.usage != nil {
		_ = d.usage.Close()
	}
	d.awake.Close()
	_ = d.store.Close()
}

// Status reports the daemon on the admin socket.
func (d *daemon) Status() admin.Status {
	st := admin.Status{
		Daemon: version, Started: d.started, Uptime: time.Since(d.started).Round(time.Second).Seconds(),
		Emacs: string(d.store.Emacs()), Streams: d.hub.Count(), Awake: d.awake.On(), AwakeHeld: d.awake.Held(),
		Host: netaddr.Host(),
	}
	// The page URL uses the first listener a phone can reach, plain HTTP before TLS.
	best := -1
	rank := func(l *listener) int {
		r := 0
		if l.tls {
			r += 2
		}
		if l.loopback {
			r++
		}
		return r
	}
	for i, l := range d.listeners {
		st.Listeners = append(st.Listeners, admin.Listener{Addr: l.addr, TLS: l.tls, Loopback: l.loopback})
		if best < 0 || rank(l) < rank(d.listeners[best]) {
			best = i
		}
	}
	if best >= 0 {
		l := d.listeners[best]
		st.Scheme = "http"
		if l.tls {
			st.Scheme = "https"
		}
		if _, port, err := net.SplitHostPort(l.addr); err == nil {
			st.Port, _ = strconv.Atoi(port)
		}
	}
	return st
}

// SetAwake turns keeping the Mac awake on or off and saves the choice.
func (d *daemon) SetAwake(on bool) error {
	if err := d.awake.Set(on); err != nil {
		return err
	}
	d.settingsMu.Lock()
	defer d.settingsMu.Unlock()
	d.settings.Awake = on
	if d.cfg.SettingsFile == "" {
		return nil
	}
	if err := settings.Write(d.cfg.SettingsFile, d.settings); err != nil {
		return fmt.Errorf("keep awake is %v now, but saving it failed: %w", on, err)
	}
	return nil
}

// certReloader serves the TLS key pair, reloading it when the certificate file changes.
type certReloader struct {
	certFile, keyFile string
	mu                sync.Mutex
	cert              *tls.Certificate
	mtime             time.Time
	checked           time.Time
}

func newCertReloader(certFile, keyFile string) (*certReloader, error) {
	c := &certReloader{certFile: certFile, keyFile: keyFile}
	if err := c.load(); err != nil {
		return nil, err
	}
	return c, nil
}

func (c *certReloader) load() error {
	fi, err := os.Stat(c.certFile)
	if err != nil {
		return err
	}
	cert, err := tls.LoadX509KeyPair(c.certFile, c.keyFile)
	if err != nil {
		return err
	}
	c.cert, c.mtime = &cert, fi.ModTime()
	return nil
}

func (c *certReloader) get(*tls.ClientHelloInfo) (*tls.Certificate, error) {
	c.mu.Lock()
	defer c.mu.Unlock()
	if time.Since(c.checked) > time.Minute {
		c.checked = time.Now()
		if fi, err := os.Stat(c.certFile); err == nil && !fi.ModTime().Equal(c.mtime) {
			_ = c.load()
		}
	}
	return c.cert, nil
}
