// Package state reads and writes the daemon's state file, which carries derived state across restarts.
package state

import (
	"encoding/json"
	"errors"
	"fmt"
	"os"
	"path/filepath"
	"time"

	"github.com/guiyuanju/overlook/remote/internal/api"
	"github.com/guiyuanju/overlook/remote/internal/store"
)

// Format is the version of the file layout; files of another version are ignored.
const Format = 1

// ErrFormat reports a state file written in another format.
var ErrFormat = errors.New("state: unsupported format")

// File is the state file's content.
type File struct {
	Format   int                `json:"format"`
	SavedAt  time.Time          `json:"savedAt"`
	Daemon   string             `json:"daemon"`
	Secret   []byte             `json:"secret"`
	Store    *store.Saved       `json:"store"`
	Receipts []api.SavedReceipt `json:"receipts"`
}

// Load reads path; a missing file is an os.ErrNotExist error.
func Load(path string) (*File, error) {
	data, err := os.ReadFile(path)
	if err != nil {
		return nil, err
	}
	var head struct {
		Format int `json:"format"`
	}
	if err := json.Unmarshal(data, &head); err != nil {
		return nil, fmt.Errorf("state: %w", err)
	}
	if head.Format != Format {
		return nil, fmt.Errorf("%w %d (want %d)", ErrFormat, head.Format, Format)
	}
	var f File
	if err := json.Unmarshal(data, &f); err != nil {
		return nil, fmt.Errorf("state: %w", err)
	}
	if f.Store == nil {
		return nil, errors.New("state: no store")
	}
	return &f, nil
}

// Write replaces path atomically with f, readable only by its owner.
func Write(path string, f *File) error {
	f.Format = Format
	data, err := json.Marshal(f)
	if err != nil {
		return err
	}
	dir := filepath.Dir(path)
	if err := os.MkdirAll(dir, 0o700); err != nil {
		return err
	}
	tmp, err := os.CreateTemp(dir, "."+filepath.Base(path)+".*")
	if err != nil {
		return err
	}
	_, werr := tmp.Write(data)
	serr := tmp.Sync()
	cerr := tmp.Close()
	if err := errors.Join(werr, serr, cerr); err != nil {
		_ = os.Remove(tmp.Name())
		return err
	}
	if err := os.Rename(tmp.Name(), path); err != nil {
		_ = os.Remove(tmp.Name())
		return err
	}
	return nil
}
