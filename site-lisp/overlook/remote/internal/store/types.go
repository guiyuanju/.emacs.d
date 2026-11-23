// Package store holds all derived state and produces the browser wire types
// of api/openapi.yaml.
package store

import (
	"bytes"
	"encoding/json"

	"github.com/guiyuanju/overlook/remote/internal/bridge"
)

// Shapes the browser API shares with the bridge unchanged.
type (
	UsageWindow = bridge.UsageWindow
	Command     = bridge.Command
	Choice      = bridge.Choice
	Form        = bridge.Form
	QueueItem   = bridge.QueueItem
	Controls    = bridge.Controls
	Status      = bridge.Status
)

// EmacsStatus is "online" or "offline".
type EmacsStatus string

const (
	EmacsOnline  EmacsStatus = "online"
	EmacsOffline EmacsStatus = "offline"
)

// Dashboard is the GET /dashboard body.
type Dashboard struct {
	Emacs    EmacsStatus `json:"emacs"`
	Known    string      `json:"known"`
	Sections []NodeRef   `json:"sections"`
}

// DashboardDelta is the data of a dashboard stream event.
type DashboardDelta struct {
	Known    string    `json:"known"`
	Sections []NodeRef `json:"sections"`
}

// Node is a dashboard node with its derived id, hash and unread count.
type Node struct {
	ID           string        `json:"id"`
	Hash         string        `json:"hash"`
	Kind         string        `json:"kind"`
	Title        string        `json:"title"`
	Subtitle     string        `json:"subtitle,omitempty"`
	Note         string        `json:"note,omitempty"`
	Provider     string        `json:"provider,omitempty"`
	Status       string        `json:"status,omitempty"`
	Account      string        `json:"account,omitempty"`
	Branch       string        `json:"branch,omitempty"`
	Added        int           `json:"added,omitempty"`
	Removed      int           `json:"removed,omitempty"`
	Due          string        `json:"due,omitempty"`
	Persona      string        `json:"persona,omitempty"`
	Description  string        `json:"description,omitempty"`
	Windows      []UsageWindow `json:"windows,omitempty"`
	Heading      bool          `json:"heading,omitempty"`
	Attention    bool          `json:"attention,omitempty"`
	Conversation string        `json:"conversation,omitempty"`
	UnreadCount  int           `json:"unreadCount,omitempty"`
	Choices      []Choice      `json:"choices,omitempty"`
	Commands     []Command     `json:"commands,omitempty"`
	Diff         bool          `json:"diff,omitempty"`
	Children     []NodeRef     `json:"children,omitempty"`
}

// NodeRef is a full node, or {same: hash} for a subtree the client holds.
type NodeRef struct {
	Node *Node
	Same string
}

type sameRef struct {
	Same string `json:"same"`
}

// MarshalJSON writes the node, or the same placeholder when Node is nil.
func (r NodeRef) MarshalJSON() ([]byte, error) {
	if r.Node == nil {
		return json.Marshal(sameRef{r.Same})
	}
	return json.Marshal(r.Node)
}

// UnmarshalJSON reads either form, telling them apart by the first key.
func (r *NodeRef) UnmarshalJSON(data []byte) error {
	*r = NodeRef{}
	dec := json.NewDecoder(bytes.NewReader(data))
	if _, err := dec.Token(); err != nil {
		return err
	}
	if key, err := dec.Token(); err == nil && key == "same" {
		var s sameRef
		err := json.Unmarshal(data, &s)
		r.Same = s.Same
		return err
	}
	r.Node = new(Node)
	return json.Unmarshal(data, r.Node)
}

// Conversation is a conversation as browsers see it: no root, plus unread state.
type Conversation struct {
	ID          string      `json:"id"`
	Provider    string      `json:"provider"`
	Title       string      `json:"title"`
	Status      Status      `json:"status"`
	Persona     string      `json:"persona,omitempty"`
	Description string      `json:"description,omitempty"`
	Project     string      `json:"project,omitempty"`
	Folder      string      `json:"folder,omitempty"`
	Brief       string      `json:"brief,omitempty"`
	Context     *float64    `json:"context,omitempty"`
	Choices     []Choice    `json:"choices,omitempty"`
	Form        *Form       `json:"form,omitempty"`
	Queue       []QueueItem `json:"queue,omitempty"`
	QueueError  string      `json:"queueError,omitempty"`
	Controls    Controls    `json:"controls"`
	CanAttach   bool        `json:"canAttach,omitempty"`
	UnreadCount int         `json:"unreadCount,omitempty"`
	ReadThrough int64       `json:"readThrough,omitempty"`
}

// ItemType names an activity item.
type ItemType = bridge.EventType

// Item is one activity item; text items carry a suffix after Offset UTF-16 units.
type Item struct {
	Item      int64    `json:"item"`
	Seq       int64    `json:"seq"`
	Type      ItemType `json:"type"`
	CreatedAt string   `json:"createdAt"`
	UpdatedAt string   `json:"updatedAt"`
	Text      string   `json:"text,omitempty"`
	Offset    int      `json:"offset,omitempty"`
	Title     string   `json:"title,omitempty"`
	Status    string   `json:"status,omitempty"`
	Kind      string   `json:"kind,omitempty"`
	Diff      string   `json:"diff,omitempty"`
	Images    []string `json:"images,omitempty"`
}

// History tells whether older items are retained.
type History struct {
	HasMore bool  `json:"hasMore"`
	Before  int64 `json:"before,omitempty"`
}

// Earlier is the fallback shown when no activity is retained.
type Earlier = bridge.EarlierResult

// ConversationList is the GET /conversations body.
type ConversationList struct {
	Epoch         string         `json:"epoch"`
	Emacs         EmacsStatus    `json:"emacs"`
	Conversations []Conversation `json:"conversations"`
}

// ConversationSnapshot is the GET /conversations/{id} body and, with Reset, a reset stream event.
type ConversationSnapshot struct {
	Reset        bool         `json:"reset,omitempty"`
	Epoch        string       `json:"epoch"`
	Seq          int64        `json:"seq"`
	Known        string       `json:"known"`
	Emacs        EmacsStatus  `json:"emacs"`
	Conversation Conversation `json:"conversation"`
	Items        []Item       `json:"items"`
	History      History      `json:"history"`
	Earlier      *Earlier     `json:"earlier,omitempty"`
}

// ConversationDelta is the data of a conversation stream event without reset.
type ConversationDelta struct {
	Epoch        string        `json:"epoch"`
	Seq          int64         `json:"seq"`
	Known        string        `json:"known"`
	Conversation *Conversation `json:"conversation,omitempty"`
	Items        []Item        `json:"items,omitempty"`
}

// HistoryPage is the GET /conversations/{id}/history body.
type HistoryPage struct {
	Epoch   string `json:"epoch"`
	Items   []Item `json:"items"`
	HasMore bool   `json:"hasMore"`
	Before  int64  `json:"before,omitempty"`
}

// ReadResult is the PUT /conversations/{id}/read body.
type ReadResult struct {
	ReadThrough int64 `json:"readThrough"`
	UnreadCount int   `json:"unreadCount"`
}

// StreamHello is the data of the first stream event.
type StreamHello struct {
	Protocol int         `json:"protocol"`
	Epoch    string      `json:"epoch"`
	Emacs    EmacsStatus `json:"emacs"`
}

// StreamStatus is the data of a status stream event.
type StreamStatus struct {
	Emacs EmacsStatus `json:"emacs"`
	Epoch string      `json:"epoch,omitempty"`
}

// StreamGone is the data of a gone stream event.
type StreamGone struct {
	Conversation string `json:"conversation"`
}
