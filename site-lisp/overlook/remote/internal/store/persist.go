package store

import (
	"os"
	"path/filepath"
	"slices"
	"strconv"
	"time"

	"github.com/guiyuanju/overlook/remote/internal/bridge"
)

// Saved is the store's state as written to the daemon's state file.
type Saved struct {
	EmacsEpoch string              `json:"emacsEpoch"`
	EpochBase  string              `json:"epochBase"`
	EpochN     int                 `json:"epochN"`
	Seq        int64               `json:"seq"`
	Synced     bool                `json:"synced"`
	Dashboard  []bridge.Node       `json:"dashboard"`
	Versions   []SavedVersion      `json:"versions"`
	Order      []string            `json:"order"`
	Convs      []SavedConversation `json:"conversations"`
	Images     []SavedImage        `json:"images"`
}

// SavedVersion is a retained dashboard version: its cursor and node hashes.
type SavedVersion struct {
	Known  string   `json:"known"`
	Hashes []string `json:"hashes"`
}

// SavedConversation is a conversation's state, items and read position.
type SavedConversation struct {
	ID          string               `json:"id"`
	State       *bridge.Conversation `json:"state,omitempty"`
	Items       []SavedItem          `json:"items"`
	Floor       int64                `json:"floor"`
	ReadThrough int64                `json:"readThrough"`
	LastSeq     int64                `json:"lastSeq"`
}

// SavedItem is an activity item; tool diffs are recomputed from the next event that carries them.
type SavedItem struct {
	ID        int64            `json:"id"`
	Seq       int64            `json:"seq"`
	Type      bridge.EventType `json:"type"`
	CreatedAt time.Time        `json:"createdAt"`
	Updated   time.Time        `json:"updated"`
	Text      string           `json:"text,omitempty"`
	Units     int              `json:"units,omitempty"`
	Marks     [][3]int64       `json:"marks,omitempty"`
	Open      bool             `json:"open,omitempty"`
	ToolID    string           `json:"toolId,omitempty"`
	Title     string           `json:"title,omitempty"`
	Status    string           `json:"status,omitempty"`
	Kind      string           `json:"kind,omitempty"`
	Diff      string           `json:"diff,omitempty"`
	Images    []string         `json:"images,omitempty"`
	Paths     []string         `json:"paths,omitempty"`
}

// SavedImage is an image store entry; its file is images/<id> in the store's directory.
type SavedImage struct {
	ID   string `json:"id"`
	MIME string `json:"mime"`
	Size int64  `json:"size"`
}

// Version counts applied changes, so a saver can tell whether anything moved since it last saved.
func (s *Store) Version() uint64 {
	s.mu.Lock()
	defer s.mu.Unlock()
	return s.version
}

// Save copies the state to persist; it is cheap under the lock, encoding happens outside.
func (s *Store) Save() *Saved {
	s.mu.Lock()
	out := &Saved{
		EmacsEpoch: s.emacsEpoch, EpochBase: s.epochBase, EpochN: s.epochN, Seq: s.seq, Synced: s.synced,
		Dashboard: s.raw, Order: append([]string(nil), s.order...),
	}
	for _, v := range s.versions {
		sv := SavedVersion{Known: v.known, Hashes: make([]string, 0, len(v.hashes))}
		for h := range v.hashes {
			sv.Hashes = append(sv.Hashes, h)
		}
		out.Versions = append(out.Versions, sv)
	}
	for _, cv := range s.convs {
		sc := SavedConversation{ID: cv.id, State: cv.state, Floor: cv.floor, ReadThrough: cv.readThrough, LastSeq: cv.lastSeq}
		for _, it := range cv.items {
			si := SavedItem{
				ID: it.id, Seq: it.seq, Type: it.typ, CreatedAt: it.createdAt, Updated: it.updated, Text: it.text,
				Units: it.units, Open: it.open, ToolID: it.toolID, Title: it.title, Status: it.status, Kind: it.kind,
				Diff: it.diff, Images: append([]string(nil), it.images...),
			}
			for _, m := range it.marks {
				si.Marks = append(si.Marks, [3]int64{m.seq, int64(m.units), int64(m.size)})
			}
			for p := range it.paths {
				si.Paths = append(si.Paths, p)
			}
			sc.Items = append(sc.Items, si)
		}
		out.Convs = append(out.Convs, sc)
	}
	s.mu.Unlock()
	out.Images = s.media.save()
	return out
}

// Restore replaces the state of a store that has not served yet with saved; Emacs stays offline.
// A nil saved only clears images a previous run left in the store's directory.
func (s *Store) Restore(saved *Saved) {
	if saved == nil {
		s.media.restore(nil)
		return
	}
	s.mu.Lock()
	s.emacsEpoch, s.epochBase, s.epochN, s.seq, s.synced = saved.EmacsEpoch, saved.EpochBase, saved.EpochN, saved.Seq, saved.Synced
	s.epoch = s.epochBase + "-" + strconv.Itoa(s.epochN)
	s.raw = saved.Dashboard
	s.order = append([]string(nil), saved.Order...)
	s.convs = map[string]*conv{}
	for _, sc := range saved.Convs {
		cv := &conv{id: sc.ID, state: sc.State, floor: sc.Floor, readThrough: sc.ReadThrough, lastSeq: sc.LastSeq}
		for _, si := range sc.Items {
			it := &item{
				id: si.ID, seq: si.Seq, typ: si.Type, createdAt: si.CreatedAt, updated: si.Updated, text: si.Text,
				units: si.Units, open: si.Open, toolID: si.ToolID, title: si.Title, status: si.Status, kind: si.Kind,
				diff: si.Diff, images: si.Images,
			}
			for _, m := range si.Marks {
				it.marks = append(it.marks, mark{seq: m[0], units: int(m[1]), size: int(m[2])})
			}
			if len(si.Paths) > 0 {
				it.paths = map[string]bool{}
				for _, p := range si.Paths {
					it.paths[p] = true
				}
			}
			cv.items = append(cv.items, it)
		}
		s.refresh(cv)
		s.convs[sc.ID] = cv
	}
	s.versions = nil
	for _, sv := range saved.Versions {
		v := &dashVersion{known: sv.Known, hashes: make(map[string]struct{}, len(sv.Hashes)), sections: []NodeRef{}}
		for _, h := range sv.Hashes {
			v.hashes[h] = struct{}{}
		}
		s.versions = append(s.versions, v)
	}
	s.dash = &dashVersion{hashes: map[string]struct{}{}, sections: []NodeRef{}}
	if len(s.versions) > 0 {
		// Deriving the current version again from the same input gives the saved cursor, which replaces its stub.
		s.dash.known = "\x00"
		s.rebuild()
		if len(s.versions) > 1 && s.versions[1].known == s.dash.known {
			s.versions = slices.Delete(s.versions, 1, 2)
		}
	} else {
		s.rebuild()
	}
	s.connected, s.online = false, false
	s.mu.Unlock()
	s.media.restore(saved.Images)
}

// save lists the image index, most recently used first.
func (m *media) save() []SavedImage {
	m.mu.Lock()
	defer m.mu.Unlock()
	out := make([]SavedImage, 0, m.lru.Len())
	for el := m.lru.Front(); el != nil; el = el.Next() {
		e := el.Value.(*mediaEntry)
		out = append(out, SavedImage{ID: e.id, MIME: e.mime, Size: e.size})
	}
	return out
}

// restore loads an image index, skipping entries whose file is gone and deleting files it does not list.
func (m *media) restore(images []SavedImage) {
	m.mu.Lock()
	defer m.mu.Unlock()
	defer m.removeOrphans()
	for _, img := range images {
		if _, ok := m.byID[img.ID]; ok {
			continue
		}
		path := filepath.Join(m.dir, "images", img.ID)
		if fi, err := os.Stat(path); err != nil || !fi.Mode().IsRegular() || filepath.Base(path) != img.ID {
			continue
		}
		m.byID[img.ID] = m.lru.PushBack(&mediaEntry{id: img.ID, mime: img.MIME, path: path, size: img.Size})
		m.total += img.Size
	}
}

func (m *media) removeOrphans() {
	dir := filepath.Join(m.dir, "images")
	entries, err := os.ReadDir(dir)
	if err != nil {
		return
	}
	for _, e := range entries {
		if _, ok := m.byID[e.Name()]; !ok {
			_ = os.Remove(filepath.Join(dir, e.Name()))
		}
	}
}
