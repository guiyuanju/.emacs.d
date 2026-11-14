package assets

import (
	"bytes"
	"compress/gzip"
	"errors"
	"log/slog"
	"os"
	"path/filepath"
	"runtime"
	"strconv"
	"sync"
	"sync/atomic"
	"time"

	"github.com/andybalholm/brotli"
)

// fastLevel is the brotli quality used while a changed file waits for its full-quality variant.
const fastLevel = 5

// pruneAge is how long cache files no build refers to are kept, so a rollback still starts fast.
const pruneAge = 7 * 24 * time.Hour

// variants are the compressed forms of one content; full says they have the configured quality.
type variants struct {
	br, gz []byte
	full   bool
}

// cache holds compressed variants by content hash, in memory and optionally on disk.
type cache struct {
	dir   string
	level int
	log   *slog.Logger

	mu      sync.Mutex
	mem     map[string]*variants
	pending map[string]bool
	// upgraded is set when full-quality variants replaced fast ones, so the next refresh picks them up.
	upgraded atomic.Bool
	bg       sync.WaitGroup
}

func newCache(dir string, level int, log *slog.Logger) *cache {
	return &cache{dir: dir, level: level, log: log, mem: map[string]*variants{}, pending: map[string]bool{}}
}

func (c *cache) brName(sum string) string { return sum + "-q" + strconv.Itoa(c.level) + ".br" }

func gzName(sum string) string { return sum + ".gz" }

func worth(f *file) bool { return compressible(f.ctype) && len(f.raw) > 256 }

// fill attaches compressed variants to every compressible file of s, compressing what is missing;
// fast compresses misses at fastLevel and upgrades them in the background.
func (c *cache) fill(s *set, fast bool) {
	var wg sync.WaitGroup
	sem := make(chan struct{}, runtime.GOMAXPROCS(0))
	for _, f := range s.files {
		if !worth(f) {
			continue
		}
		if v := c.lookup(f.sum); v != nil {
			attach(f, v)
			continue
		}
		wg.Add(1)
		go func() {
			defer wg.Done()
			sem <- struct{}{}
			defer func() { <-sem }()
			level := c.level
			if fast {
				level = min(level, fastLevel)
			}
			v := compress(f.raw, level)
			v.full = level == c.level
			if v.full {
				c.store(f.sum, v)
			} else {
				c.put(f.sum, v)
				c.upgrade(f)
			}
			attach(f, v)
		}()
	}
	wg.Wait()
}

func attach(f *file, v *variants) {
	f.br, f.gz = nil, nil
	if len(v.br) < len(f.raw) {
		f.br = v.br
	}
	if len(v.gz) < len(f.raw) {
		f.gz = v.gz
	}
}

func compress(raw []byte, level int) *variants {
	var gz, br bytes.Buffer
	gw, _ := gzip.NewWriterLevel(&gz, gzip.BestCompression)
	_, _ = gw.Write(raw)
	_ = gw.Close()
	bw := brotli.NewWriterLevel(&br, level)
	_, _ = bw.Write(raw)
	_ = bw.Close()
	return &variants{br: br.Bytes(), gz: gz.Bytes()}
}

// lookup returns the variants of sum from memory or disk, or nil.
func (c *cache) lookup(sum string) *variants {
	c.mu.Lock()
	v := c.mem[sum]
	c.mu.Unlock()
	if v != nil || c.dir == "" {
		return v
	}
	br, err1 := os.ReadFile(filepath.Join(c.dir, c.brName(sum)))
	gz, err2 := os.ReadFile(filepath.Join(c.dir, gzName(sum)))
	if err1 != nil || err2 != nil {
		return nil
	}
	v = &variants{br: br, gz: gz, full: true}
	c.put(sum, v)
	return v
}

func (c *cache) put(sum string, v *variants) {
	c.mu.Lock()
	defer c.mu.Unlock()
	if old := c.mem[sum]; old == nil || !old.full || v.full {
		c.mem[sum] = v
	}
}

// store keeps full-quality variants in memory and on disk.
func (c *cache) store(sum string, v *variants) {
	c.put(sum, v)
	if c.dir == "" {
		return
	}
	if err := os.MkdirAll(c.dir, 0o700); err != nil {
		c.log.Warn("asset cache", "err", err)
		return
	}
	for name, data := range map[string][]byte{c.brName(sum): v.br, gzName(sum): v.gz} {
		if err := writeAtomic(filepath.Join(c.dir, name), data); err != nil {
			c.log.Warn("asset cache", "err", err)
		}
	}
}

// upgrade compresses f at full quality in the background.
func (c *cache) upgrade(f *file) {
	c.mu.Lock()
	if c.pending[f.sum] {
		c.mu.Unlock()
		return
	}
	c.pending[f.sum] = true
	c.mu.Unlock()
	c.bg.Add(1)
	go func() {
		defer c.bg.Done()
		v := compress(f.raw, c.level)
		v.full = true
		c.store(f.sum, v)
		c.mu.Lock()
		delete(c.pending, f.sum)
		c.mu.Unlock()
		c.upgraded.Store(true)
	}()
}

// retain forgets in-memory variants no build in sets refers to.
func (c *cache) retain(sets []*set) {
	keep := map[string]bool{}
	for _, s := range sets {
		for _, f := range s.files {
			keep[f.sum] = true
		}
	}
	c.mu.Lock()
	defer c.mu.Unlock()
	for sum := range c.mem {
		if !keep[sum] && !c.pending[sum] {
			delete(c.mem, sum)
		}
	}
}

// prune deletes old cache files that s does not use.
func (c *cache) prune(s *set) {
	if c.dir == "" {
		return
	}
	keep := map[string]bool{}
	for _, f := range s.files {
		keep[c.brName(f.sum)], keep[gzName(f.sum)] = true, true
	}
	entries, err := os.ReadDir(c.dir)
	if err != nil {
		return
	}
	for _, e := range entries {
		info, err := e.Info()
		if err != nil || keep[e.Name()] || e.IsDir() || time.Since(info.ModTime()) < pruneAge {
			continue
		}
		_ = os.Remove(filepath.Join(c.dir, e.Name()))
	}
}

// writeAtomic writes data to a 0600 file via a temporary file and rename.
func writeAtomic(name string, data []byte) error {
	tmp, err := os.CreateTemp(filepath.Dir(name), "."+filepath.Base(name)+".*")
	if err != nil {
		return err
	}
	_, werr := tmp.Write(data)
	cerr := tmp.Close()
	if err := errors.Join(werr, cerr); err != nil {
		_ = os.Remove(tmp.Name())
		return err
	}
	if err := os.Rename(tmp.Name(), name); err != nil {
		_ = os.Remove(tmp.Name())
		return err
	}
	return nil
}
