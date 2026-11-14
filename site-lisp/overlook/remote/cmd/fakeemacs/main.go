// Command fakeemacs connects to a running overlook-remoted as Emacs and replays fixtures; SIGUSR1 replays live.ndjson.
package main

import (
	"context"
	"flag"
	"fmt"
	"os"
	"os/signal"
	"syscall"
	"time"

	"github.com/guiyuanju/overlook/remote/internal/config"
	"github.com/guiyuanju/overlook/remote/internal/fakeemacs"
)

func main() {
	socket := flag.String("socket", config.DefaultSocket(), "daemon bridge socket `path`")
	dir := flag.String("fixtures", "testdata/fixtures", "fixtures `dir`")
	speed := flag.Float64("speed", 1, "speed factor of live steps")
	delay := flag.Duration("live-delay", time.Second, "wait before live steps play (negative: only on SIGUSR1)")
	flag.Parse()
	fx, err := fakeemacs.Load(*dir)
	if err != nil {
		fmt.Fprintln(os.Stderr, "fakeemacs:", err)
		os.Exit(2)
	}
	ctx, stop := signal.NotifyContext(context.Background(), os.Interrupt, syscall.SIGTERM)
	defer stop()
	f := &fakeemacs.Fake{Socket: *socket, Fixtures: fx, Speed: *speed, LiveDelay: *delay}
	usr1 := make(chan os.Signal, 1)
	signal.Notify(usr1, syscall.SIGUSR1)
	go func() {
		for range usr1 {
			f.PlayLive()
		}
	}()
	if err := f.Run(ctx); err != nil {
		fmt.Fprintln(os.Stderr, "fakeemacs:", err)
		os.Exit(1)
	}
}
