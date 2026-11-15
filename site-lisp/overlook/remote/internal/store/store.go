package store

import (
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"errors"
	"fmt"
	"os"
	"path/filepath"
	"slices"
	"sort"
	"strconv"
	"strings"
	"sync"
	"time"
	"unicode/utf16"

	"github.com/guiyuanju/overlook/remote/internal/bridge"
)

// Retention and paging limits.
const (
	DashboardVersions = 32
	ItemsRetained     = 300
	PageSize          = 50
	MaxPageSize       = 100
	DiffChars         = 20000
	// scanBack bounds how much earlier text of an open item is rescanned for image paths.
	scanBack = 8 << 10
)

// Errors returned by reads; the api maps them to problems.
var (
	ErrConversationMissing = errors.New("store: conversation missing")
	ErrNodeMissing         = errors.New("store: node missing")
	ErrHistoryExpired      = errors.New("store: history expired")
	ErrImageMissing        = errors.New("store: image missing")
)

// Change tells subscribers what moved since the last notification.
type Change struct {
	Dashboard     bool
	Status        bool
	Conversations []string
	Gone          []string
	// Epoch is set when a new history epoch began (Emacs restarted).
	Epoch bool
}

func (c Change) empty() bool {
	return !c.Dashboard && !c.Status && !c.Epoch && len(c.Conversations) == 0 && len(c.Gone) == 0
}

// Options configures a Store.
type Options struct {
	// Dir is a 0700 directory for images and uploads; empty means a new temporary one.
	Dir string
	// Now is the clock; nil means time.Now.
	Now func() time.Time
	// MaxImages and MaxImageBytes bound the image store; zero means the defaults.
	MaxImages     int
	MaxImageBytes int64
}

// Store is the daemon's derived state; it implements bridge.Sink.
type Store struct {
	mu       sync.Mutex
	opts     Options
	watchers []func(Change)
	media    *media
	ownDir   bool

	connected  bool
	online     bool
	emacsEpoch string
	epochBase  string
	epochN     int
	epoch      string
	seq        int64

	raw      []bridge.Node
	synced   bool
	dash     *dashVersion
	versions []*dashVersion
	nodes    map[string]nodeEntry

	order []string
	convs map[string]*conv
	// version counts updates, for Version.
	version uint64
}

var _ bridge.Sink = (*Store)(nil)

type dashVersion struct {
	known    string
	sections []NodeRef
	hashes   map[string]struct{}
}

type nodeEntry struct {
	path []string
	raw  bridge.Node
}

type mark struct {
	seq         int64
	units, size int
}

type item struct {
	id, seq            int64
	typ                bridge.EventType
	createdAt, updated time.Time
	text               string
	units              int
	marks              []mark
	open               bool
	toolID             string
	title, status      string
	kind, diff         string
	diffs              []bridge.Diff
	images             []string
	paths              map[string]bool
}

type conv struct {
	id          string
	state       *bridge.Conversation
	items       []*item
	floor       int64
	readThrough int64
	lastSeq     int64
	unread      int
	known       string
	view        Conversation
}

// New returns an empty store, Emacs offline.
func New(opts Options) *Store {
	if opts.Now == nil {
		opts.Now = time.Now
	}
	if opts.MaxImages <= 0 {
		opts.MaxImages = DefaultMaxImages
	}
	if opts.MaxImageBytes <= 0 {
		opts.MaxImageBytes = DefaultMaxImageBytes
	}
	s := &Store{opts: opts, convs: map[string]*conv{}, nodes: map[string]nodeEntry{}}
	if s.opts.Dir == "" {
		dir, err := os.MkdirTemp("", "overlook-remoted-")
		if err == nil {
			s.opts.Dir, s.ownDir = dir, true
		}
	}
	s.media = newMedia(s.opts.Dir, opts.MaxImages, opts.MaxImageBytes)
	s.epochBase = strconv.FormatInt(opts.Now().UnixMilli(), 36)
	s.newEpoch()
	s.dash = &dashVersion{hashes: map[string]struct{}{}, sections: []NodeRef{}}
	return s
}

// Close removes the temporary directory New made.
func (s *Store) Close() error {
	if s.ownDir {
		return os.RemoveAll(s.opts.Dir)
	}
	return nil
}

func (s *Store) newEpoch() {
	s.epochN++
	s.epoch = s.epochBase + "-" + strconv.Itoa(s.epochN)
}

// OnChange registers fn, called after each applied change outside the lock.
func (s *Store) OnChange(fn func(Change)) {
	s.mu.Lock()
	defer s.mu.Unlock()
	s.watchers = append(s.watchers, fn)
}

func (s *Store) emit(c Change) {
	if c.empty() {
		return
	}
	s.mu.Lock()
	ws := slices.Clone(s.watchers)
	s.mu.Unlock()
	for _, w := range ws {
		w(c)
	}
}

// update runs fn under the lock and emits the change it returns.
func (s *Store) update(fn func() Change) {
	s.mu.Lock()
	c := fn()
	s.version++
	s.mu.Unlock()
	s.emit(c)
}

func hash16(parts ...[]byte) string {
	h := sha256.New()
	for _, p := range parts {
		h.Write(p)
		h.Write([]byte{0})
	}
	return hex.EncodeToString(h.Sum(nil)[:8])
}

func jsonHash(v any) string {
	data, _ := json.Marshal(v)
	return hash16(data)
}

// Connected starts or resumes a session per the Emacs epoch rules.
func (s *Store) Connected(hello bridge.HelloParams) string {
	var epoch string
	s.update(func() Change {
		fresh := s.emacsEpoch == "" || hello.Epoch != s.emacsEpoch
		s.emacsEpoch = hello.Epoch
		s.connected, s.online = true, false
		var c Change
		c.Status = true
		if fresh {
			s.newEpoch()
			s.seq = 0
			for id, cv := range s.convs {
				if cv.state == nil {
					delete(s.convs, id)
					continue
				}
				cv.items, cv.floor, cv.readThrough, cv.lastSeq = nil, 0, 0, 0
				s.refresh(cv)
				c.Conversations = append(c.Conversations, id)
			}
			c.Epoch = true
			c.Dashboard = s.rebuild()
		}
		if hello.Lost > 0 {
			for _, cv := range s.convs {
				for _, it := range cv.items {
					it.open = false
				}
			}
		}
		epoch = s.epoch
		return c
	})
	return epoch
}

// Sync replaces dashboard and conversations and marks Emacs online.
func (s *Store) Sync(p bridge.SyncParams) {
	s.update(func() Change {
		c := Change{Dashboard: true, Status: true}
		s.online = s.connected
		keep := map[string]bool{}
		s.order = s.order[:0]
		for i := range p.Conversations {
			st := p.Conversations[i]
			if keep[st.ID] {
				continue
			}
			keep[st.ID] = true
			s.order = append(s.order, st.ID)
			cv := s.convs[st.ID]
			if cv == nil {
				cv = &conv{id: st.ID}
				s.convs[st.ID] = cv
			}
			cv.state = &st
			s.refresh(cv)
			c.Conversations = append(c.Conversations, st.ID)
		}
		for id := range s.convs {
			if !keep[id] {
				delete(s.convs, id)
				c.Gone = append(c.Gone, id)
			}
		}
		s.raw, s.synced = p.Dashboard, true
		s.rebuild()
		return c
	})
}

// SetDashboard derives ids, hashes and unread overlay and records a version when the root hash changes.
func (s *Store) SetDashboard(p bridge.DashboardSetParams) {
	s.update(func() Change {
		s.raw, s.synced = p.Sections, true
		return Change{Dashboard: s.rebuild()}
	})
}

// SetConversation creates or replaces a conversation state.
func (s *Store) SetConversation(p bridge.ConversationSetParams) {
	st := p.Conversation
	s.update(func() Change {
		cv := s.convs[st.ID]
		if cv == nil {
			cv = &conv{id: st.ID}
			s.convs[st.ID] = cv
		}
		appeared := cv.state == nil
		if appeared {
			s.order = append(s.order, st.ID)
		}
		cv.state = &st
		unread := s.refresh(cv)
		c := Change{Conversations: []string{st.ID}}
		if appeared || unread {
			c.Dashboard = s.rebuild()
		}
		return c
	})
}

// RemoveConversation drops a conversation, its activity and read position.
func (s *Store) RemoveConversation(p bridge.ConversationParams) {
	s.update(func() Change {
		if _, ok := s.convs[p.Conversation]; !ok {
			return Change{}
		}
		delete(s.convs, p.Conversation)
		s.order = slices.DeleteFunc(s.order, func(id string) bool { return id == p.Conversation })
		return Change{Gone: []string{p.Conversation}, Dashboard: s.rebuild()}
	})
}

// Disconnected marks Emacs offline, keeping the last snapshot.
func (s *Store) Disconnected() {
	s.update(func() Change {
		s.connected, s.online = false, false
		return Change{Status: true}
	})
}

// Emacs reports whether Emacs is synced.
func (s *Store) Emacs() EmacsStatus {
	s.mu.Lock()
	defer s.mu.Unlock()
	return s.emacsLocked()
}

func (s *Store) emacsLocked() EmacsStatus {
	if s.online {
		return EmacsOnline
	}
	return EmacsOffline
}

// Epoch is the current history epoch.
func (s *Store) Epoch() string {
	s.mu.Lock()
	defer s.mu.Unlock()
	return s.epoch
}

// rebuild derives the dashboard from raw and records a version; it reports whether the version changed.
func (s *Store) rebuild() bool {
	nodes := map[string]nodeEntry{}
	hashes := map[string]struct{}{}
	sections := s.buildNodes(s.raw, "", nil, nodes, hashes)
	known := ""
	if s.synced {
		parts := make([][]byte, 0, len(sections))
		for _, r := range sections {
			parts = append(parts, []byte(r.Node.Hash))
		}
		known = hash16(parts...)
	}
	s.nodes = nodes
	if known == s.dash.known {
		return false
	}
	s.dash = &dashVersion{known: known, sections: sections, hashes: hashes}
	s.versions = append([]*dashVersion{s.dash}, s.versions...)
	if len(s.versions) > DashboardVersions {
		s.versions = s.versions[:DashboardVersions]
	}
	return true
}

func (s *Store) buildNodes(raw []bridge.Node, parent string, path []string, nodes map[string]nodeEntry, hashes map[string]struct{}) []NodeRef {
	out := make([]NodeRef, 0, len(raw))
	seen := map[string]int{}
	for _, r := range raw {
		seen[r.Key]++
		key := r.Key
		if n := seen[r.Key]; n > 1 {
			key = fmt.Sprintf("%s#%d", r.Key, n)
		}
		id := hash16([]byte(parent), []byte(key))
		p := append(path[:len(path):len(path)], key)
		n := &Node{
			ID: id, Kind: r.Kind, Title: r.Title, Subtitle: r.Subtitle, Provider: r.Provider, Status: r.Status,
			Account: r.Account, Branch: r.Branch, Added: r.Added, Removed: r.Removed, Due: r.Due,
			Persona: r.Persona, Description: r.Description, Windows: r.Windows, Heading: r.Heading,
			Attention: r.Attention, Conversation: r.Conversation, Choices: r.Choices, Commands: r.Commands, Diff: r.Diff,
		}
		if cv := s.convs[r.Conversation]; r.Conversation != "" && cv != nil && cv.state != nil {
			n.UnreadCount = cv.unread
		}
		children := s.buildNodes(r.Children, id, p, nodes, hashes)
		own, _ := json.Marshal(n)
		parts := [][]byte{own}
		for _, c := range children {
			parts = append(parts, []byte(c.Node.Hash))
		}
		n.Hash = hash16(parts...)
		if len(children) > 0 {
			n.Children = children
		}
		nodes[id] = nodeEntry{path: p, raw: r}
		hashes[n.Hash] = struct{}{}
		out = append(out, NodeRef{Node: n})
	}
	return out
}

func deltaRefs(refs []NodeRef, known map[string]struct{}) []NodeRef {
	out := make([]NodeRef, len(refs))
	for i, r := range refs {
		if _, ok := known[r.Node.Hash]; ok {
			out[i] = NodeRef{Same: r.Node.Hash}
			continue
		}
		cp := *r.Node
		if len(cp.Children) > 0 {
			cp.Children = deltaRefs(cp.Children, known)
		}
		out[i] = NodeRef{Node: &cp}
	}
	return out
}

// sectionsFor returns the current sections as a delta against known when that version is retained.
func (s *Store) sectionsFor(known string) []NodeRef {
	if known != "" {
		for _, v := range s.versions {
			if v.known == known {
				return deltaRefs(s.dash.sections, v.hashes)
			}
		}
	}
	return s.dash.sections
}

// Dashboard returns the current dashboard, as a delta against known when that version is retained.
func (s *Store) Dashboard(known string) Dashboard {
	s.mu.Lock()
	defer s.mu.Unlock()
	return Dashboard{Emacs: s.emacsLocked(), Known: s.dash.known, Sections: s.sectionsFor(known)}
}

// DashboardKnown is the cursor of the current dashboard version.
func (s *Store) DashboardKnown() string {
	s.mu.Lock()
	defer s.mu.Unlock()
	return s.dash.known
}

// DashboardDelta returns the change since known, ok false when known is current.
func (s *Store) DashboardDelta(known string) (delta DashboardDelta, ok bool) {
	s.mu.Lock()
	defer s.mu.Unlock()
	if known == s.dash.known {
		return DashboardDelta{}, false
	}
	return DashboardDelta{Known: s.dash.known, Sections: s.sectionsFor(known)}, true
}

// NodeTarget resolves a node id of the current version to its key path and node.
func (s *Store) NodeTarget(id string) (path []string, node bridge.Node, err error) {
	s.mu.Lock()
	defer s.mu.Unlock()
	e, ok := s.nodes[id]
	if !ok {
		return nil, bridge.Node{}, ErrNodeMissing
	}
	return slices.Clone(e.path), e.raw, nil
}

func stripSubtitles(nodes []bridge.Node) []bridge.Node {
	out := make([]bridge.Node, len(nodes))
	for i, n := range nodes {
		n.Subtitle = ""
		n.Children = stripSubtitles(n.Children)
		out[i] = n
	}
	return out
}

// NodeConfirmState hashes a node for confirmation tokens, ignoring subtitle and unreadCount recursively.
func (s *Store) NodeConfirmState(id string) (string, error) {
	_, n, err := s.NodeTarget(id)
	if err != nil {
		return "", err
	}
	return jsonHash(stripSubtitles([]bridge.Node{n})), nil
}

func (s *Store) live(id string) (*conv, error) {
	cv := s.convs[id]
	if cv == nil || cv.state == nil {
		return nil, ErrConversationMissing
	}
	return cv, nil
}

// refresh recomputes unread count, browser view and hash; it reports whether the unread count changed.
func (s *Store) refresh(cv *conv) bool {
	unread := 0
	for _, it := range cv.items {
		if it.typ == bridge.EventText && it.seq > cv.readThrough {
			unread++
		}
	}
	changed := unread != cv.unread
	cv.unread = unread
	if cv.state != nil {
		st := cv.state
		cv.view = Conversation{
			ID: st.ID, Provider: st.Provider, Title: st.Title, Status: st.Status, Persona: st.Persona,
			Description: st.Description, Project: st.Project, Folder: st.Folder, Brief: st.Brief,
			Context: st.Context, Choices: st.Choices, Form: st.Form, Queue: st.Queue, QueueError: st.QueueError,
			Controls: st.Controls, CanAttach: st.CanAttach, UnreadCount: unread, ReadThrough: cv.readThrough,
		}
		cv.known = jsonHash(cv.view)
	}
	return changed
}

// Conversations lists browser conversations in Emacs's order.
func (s *Store) Conversations() ConversationList {
	s.mu.Lock()
	defer s.mu.Unlock()
	out := ConversationList{Epoch: s.epoch, Emacs: s.emacsLocked(), Conversations: []Conversation{}}
	for _, id := range s.order {
		if cv, err := s.live(id); err == nil {
			out.Conversations = append(out.Conversations, cv.view)
		}
	}
	return out
}

// Conversation returns the published state of id, root included.
func (s *Store) Conversation(id string) (bridge.Conversation, error) {
	s.mu.Lock()
	defer s.mu.Unlock()
	cv, err := s.live(id)
	if err != nil {
		return bridge.Conversation{}, err
	}
	return *cv.state, nil
}

// ConversationConfirmState hashes a conversation for confirmation tokens, ignoring brief and context.
func (s *Store) ConversationConfirmState(id string) (string, error) {
	st, err := s.Conversation(id)
	if err != nil {
		return "", err
	}
	st.Brief, st.Context = "", nil
	return jsonHash(st), nil
}

func stamp(t time.Time) string {
	return t.UTC().Format("2006-01-02T15:04:05.000Z")
}

// wire presents it for a client holding changes through after; text items carry only the suffix it lacks.
func (it *item) wire(after int64) Item {
	w := Item{
		Item: it.id, Seq: it.seq, Type: it.typ, CreatedAt: stamp(it.createdAt), UpdatedAt: stamp(it.updated),
		Title: it.title, Status: it.status, Kind: it.kind, Diff: it.diff, Images: it.images,
	}
	switch it.typ {
	case bridge.EventText:
		units, size := 0, 0
		if after > 0 && it.id <= after {
			i := sort.Search(len(it.marks), func(i int) bool { return it.marks[i].seq > after })
			if i > 0 {
				units, size = it.marks[i-1].units, it.marks[i-1].size
			}
		}
		w.Text, w.Offset = it.text[size:], units
	case bridge.EventPrompt, bridge.EventError:
		w.Text = it.text
	}
	return w
}

func wireAll(items []*item, after int64) []Item {
	out := make([]Item, 0, len(items))
	for _, it := range items {
		out = append(out, it.wire(after))
	}
	return out
}

// Snapshot returns the conversation with its latest page; Earlier is left for the caller to fill.
func (s *Store) Snapshot(id string) (ConversationSnapshot, error) {
	s.mu.Lock()
	defer s.mu.Unlock()
	cv, err := s.live(id)
	if err != nil {
		return ConversationSnapshot{}, err
	}
	return s.snapshotLocked(cv), nil
}

func (s *Store) snapshotLocked(cv *conv) ConversationSnapshot {
	start := max(0, len(cv.items)-PageSize)
	snap := ConversationSnapshot{
		Epoch: s.epoch, Seq: cv.lastSeq, Known: cv.known, Emacs: s.emacsLocked(),
		Conversation: cv.view, Items: wireAll(cv.items[start:], 0),
	}
	if start > 0 {
		snap.History = History{HasMore: true, Before: cv.items[start].id}
	}
	return snap
}

// Delta returns what a client at (epoch, after, known) lacks.
// reset is true when it needs a snapshot instead; ok false when nothing changed.
func (s *Store) Delta(id, epoch string, after int64, known string) (delta ConversationDelta, reset, ok bool, err error) {
	s.mu.Lock()
	defer s.mu.Unlock()
	cv, err := s.live(id)
	if err != nil {
		return ConversationDelta{}, false, false, err
	}
	if epoch != s.epoch || after > s.seq || after < cv.floor {
		return ConversationDelta{}, true, true, nil
	}
	var touched []*item
	for _, it := range cv.items {
		if it.seq > after {
			touched = append(touched, it)
		}
	}
	if known == cv.known && len(touched) == 0 {
		return ConversationDelta{}, false, false, nil
	}
	delta = ConversationDelta{Epoch: s.epoch, Seq: max(cv.lastSeq, after), Known: cv.known}
	if known != cv.known {
		view := cv.view
		delta.Conversation = &view
	}
	if len(touched) > 0 {
		sort.Slice(touched, func(a, b int) bool { return touched[a].seq < touched[b].seq })
		delta.Items = wireAll(touched, after)
	}
	return delta, false, true, nil
}

// Mentions reports whether any of needles appears in a retained item of conversation id; empty means none is retained.
func (s *Store) Mentions(id string, needles ...string) (found, empty bool, err error) {
	s.mu.Lock()
	defer s.mu.Unlock()
	cv, err := s.live(id)
	if err != nil {
		return false, false, err
	}
	for _, it := range cv.items {
		for _, n := range needles {
			if n != "" && (strings.Contains(it.text, n) || strings.Contains(it.title, n)) {
				return true, false, nil
			}
		}
	}
	return false, len(cv.items) == 0, nil
}

// History returns up to limit items before item before.
func (s *Store) History(id string, before int64, limit int, epoch string) (HistoryPage, error) {
	s.mu.Lock()
	defer s.mu.Unlock()
	cv, err := s.live(id)
	if err != nil {
		return HistoryPage{}, err
	}
	if epoch != s.epoch {
		return HistoryPage{}, ErrHistoryExpired
	}
	if cv.floor > 0 && (len(cv.items) == 0 || before <= cv.items[0].id) {
		return HistoryPage{}, ErrHistoryExpired
	}
	limit = min(max(limit, 1), MaxPageSize)
	end := sort.Search(len(cv.items), func(i int) bool { return cv.items[i].id >= before })
	start := max(0, end-limit)
	page := HistoryPage{Epoch: s.epoch, Items: wireAll(cv.items[start:end], 0)}
	if start > 0 {
		page.HasMore, page.Before = true, cv.items[start].id
	}
	return page, nil
}

// Read advances the read position; caughtUp tells the caller to send conversation.seen.
func (s *Store) Read(id string, through int64, epoch string) (r ReadResult, caughtUp bool, err error) {
	s.update(func() Change {
		if epoch != s.epoch {
			err = ErrHistoryExpired
			return Change{}
		}
		cv, e := s.live(id)
		if e != nil {
			err = e
			return Change{}
		}
		var c Change
		if t := min(through, cv.lastSeq); t > cv.readThrough {
			cv.readThrough = t
			if s.refresh(cv) {
				c.Dashboard = s.rebuild()
			}
			c.Conversations = []string{id}
		}
		r = ReadResult{ReadThrough: cv.readThrough, UnreadCount: cv.unread}
		caughtUp = cv.unread == 0
		return c
	})
	return r, caughtUp, err
}

func utf16Len(s string) int {
	n := 0
	for _, r := range s {
		n += utf16.RuneLen(r)
	}
	return n
}

// eventPlan is what Event computes outside the lock before applying.
type eventPlan struct {
	images []string
	paths  []string
	diff   string
	redo   bool
}

// target finds the item e extends, or nil when e creates one.
func (cv *conv) target(e *bridge.Event) *item {
	switch e.Type {
	case bridge.EventText:
		if n := len(cv.items); n > 0 && cv.items[n-1].typ == bridge.EventText && cv.items[n-1].open {
			return cv.items[n-1]
		}
	case bridge.EventTool:
		for i := len(cv.items) - 1; i >= 0; i-- {
			if it := cv.items[i]; it.typ == bridge.EventTool && it.toolID == e.ID {
				return it
			}
		}
	}
	return nil
}

// Event applies an agent event to the activity items (protocol section 8).
func (s *Store) Event(e bridge.Event) {
	if e.Conversation == "" || e.Type == "" {
		return
	}
	if e.At.IsZero() {
		e.At = s.opts.Now()
	}
	// Plan under the lock, do file and diff work outside it, then apply.
	var root, scan string
	var tried map[string]bool
	var lastDiffs []bridge.Diff
	s.mu.Lock()
	if cv := s.convs[e.Conversation]; cv != nil {
		if cv.state != nil {
			root = cv.state.Root
		}
		if it := cv.target(&e); it != nil {
			tried = maps(it.paths)
			lastDiffs = it.diffs
			if e.Type == bridge.EventText {
				from := max(0, len(it.text)-scanBack)
				if nl := strings.LastIndexByte(it.text[from:], '\n'); nl >= 0 {
					from += nl + 1
				}
				scan = it.text[from:] + e.Text
			}
		}
	}
	s.mu.Unlock()
	switch {
	case e.Type == bridge.EventTool:
		scan = e.Title + "\n" + e.Output
	case scan == "":
		scan = e.Text
	}
	var plan eventPlan
	for _, img := range e.Images {
		var id string
		var ok bool
		if img.Data != "" {
			id, ok = s.media.addData(img.Data, img.MIME)
		} else if img.File != "" {
			f := img.File
			if !filepath.IsAbs(f) && root != "" {
				f = filepath.Join(root, f)
			}
			id, ok = s.media.addFile(f)
		}
		if ok {
			plan.images = append(plan.images, id)
		}
	}
	for _, p := range ImagePaths(scan, root) {
		if tried[p] {
			continue
		}
		if id, ok := s.media.addFile(p); ok {
			plan.images = append(plan.images, id)
			plan.paths = append(plan.paths, p)
		}
	}
	if e.Type == bridge.EventTool && len(e.Diffs) > 0 && !slices.Equal(e.Diffs, lastDiffs) {
		plan.diff, plan.redo = UnifiedDiff(e.Diffs), true
	}
	s.update(func() Change { return s.apply(&e, &plan) })
}

func maps(m map[string]bool) map[string]bool {
	out := make(map[string]bool, len(m))
	for k, v := range m {
		out[k] = v
	}
	return out
}

func (s *Store) apply(e *bridge.Event, plan *eventPlan) Change {
	cv := s.convs[e.Conversation]
	if cv == nil {
		cv = &conv{id: e.Conversation}
		s.convs[e.Conversation] = cv
	}
	s.seq++
	cv.lastSeq = s.seq
	it := cv.target(e)
	if it == nil {
		it = &item{id: s.seq, typ: e.Type, createdAt: e.At, open: e.Type == bridge.EventText, toolID: e.ID}
		if e.Type == bridge.EventPrompt || e.Type == bridge.EventError {
			it.text = e.Text
		}
		cv.items = append(cv.items, it)
		for len(cv.items) > ItemsRetained {
			old := cv.items[0]
			cv.floor = max(cv.floor, old.seq, old.id)
			cv.items = slices.Delete(cv.items, 0, 1)
		}
	}
	it.seq, it.updated = s.seq, e.At
	switch e.Type {
	case bridge.EventText:
		it.text += e.Text
		it.units += utf16Len(e.Text)
		it.marks = append(it.marks, mark{seq: s.seq, units: it.units, size: len(it.text)})
	case bridge.EventTool:
		if e.Title != "" {
			it.title = e.Title
		}
		if e.Status != "" {
			it.status = e.Status
		}
		if e.Kind != "" {
			it.kind = e.Kind
		}
		if plan.redo {
			it.diff, it.diffs = plan.diff, e.Diffs
		}
	}
	for _, id := range plan.images {
		if !slices.Contains(it.images, id) {
			it.images = append(it.images[:len(it.images):len(it.images)], id)
		}
	}
	for _, p := range plan.paths {
		if it.paths == nil {
			it.paths = map[string]bool{}
		}
		it.paths[p] = true
	}
	c := Change{}
	if cv.state == nil {
		return c
	}
	c.Conversations = []string{cv.id}
	if s.refresh(cv) {
		c.Dashboard = s.rebuild()
	}
	return c
}
