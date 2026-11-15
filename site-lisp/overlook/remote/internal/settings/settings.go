// Package settings keeps the daemon's user settings, such as keeping the Mac awake, across restarts.
package settings

import (
	"encoding/json"
	"errors"
	"io/fs"
	"os"
	"path/filepath"
)

// Settings are the daemon's user settings.
type Settings struct {
	Awake bool `json:"awake"`
}

// Default is used when there is no settings file.
var Default = Settings{Awake: true}

// Load reads path, returning Default when it does not exist.
func Load(path string) (Settings, error) {
	data, err := os.ReadFile(path)
	if errors.Is(err, fs.ErrNotExist) {
		return Default, nil
	}
	if err != nil {
		return Default, err
	}
	s := Default
	if err := json.Unmarshal(data, &s); err != nil {
		return Default, err
	}
	return s, nil
}

// Write replaces path atomically with s, readable only by its owner.
func Write(path string, s Settings) error {
	data, err := json.Marshal(s)
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
	_, werr := tmp.Write(append(data, '\n'))
	cerr := tmp.Close()
	if err := errors.Join(werr, cerr); err != nil {
		_ = os.Remove(tmp.Name())
		return err
	}
	if err := os.Rename(tmp.Name(), path); err != nil {
		_ = os.Remove(tmp.Name())
		return err
	}
	return nil
}
