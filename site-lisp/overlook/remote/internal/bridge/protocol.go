// Package bridge speaks the Emacs bridge protocol (docs/bridge-protocol.md):
// NDJSON JSON-RPC 2.0 over a unix socket, Emacs as the client.
package bridge

import (
	"bytes"
	"encoding/json"
	"errors"
	"strconv"
	"time"
)

// ProtocolVersion is the bridge protocol version exchanged in hello.
const ProtocolVersion = 1

// Methods sent by Emacs.
const (
	MethodHello              = "hello"
	MethodSync               = "sync"
	MethodDashboardSet       = "dashboard.set"
	MethodConversationSet    = "conversation.set"
	MethodConversationRemove = "conversation.remove"
	MethodAgentEvent         = "agent.event"
)

// Methods sent by the daemon.
const (
	MethodPrompt  = "conversation.prompt"
	MethodUnqueue = "conversation.unqueue"
	MethodRetry   = "conversation.retry"
	MethodAction  = "conversation.action"
	MethodChoose  = "conversation.choose"
	MethodAnswer  = "conversation.answer"
	MethodAttach  = "conversation.attach"
	MethodEarlier = "conversation.earlier"
	MethodCommand = "node.command"
	MethodDiff    = "node.diff"
	MethodPing    = "ping"
	MethodSeen    = "conversation.seen"
	MethodResync  = "resync"
)

// Size limits from section 9 of the protocol.
const (
	MaxInboundLine  = 64 << 20
	MaxOutboundLine = 1 << 20
	MaxImageBytes   = 20 << 20
)

// Timeouts are how long the daemon waits for Emacs per method.
var Timeouts = map[string]time.Duration{
	MethodEarlier: 2 * time.Second,
	MethodPing:    5 * time.Second,
	MethodAction:  30 * time.Second,
	MethodCommand: 30 * time.Second,
}

// DefaultTimeout applies to methods missing from Timeouts.
const DefaultTimeout = 10 * time.Second

// Message is one JSON-RPC 2.0 envelope: request, notification or response.
type Message struct {
	JSONRPC string          `json:"jsonrpc"`
	ID      json.RawMessage `json:"id,omitempty"`
	Method  string          `json:"method,omitempty"`
	Params  json.RawMessage `json:"params,omitempty"`
	Result  json.RawMessage `json:"result,omitempty"`
	Error   *Error          `json:"error,omitempty"`
}

// Status is a conversation's agent status.
type Status string

const (
	StatusIdle    Status = "idle"
	StatusWorking Status = "working"
	StatusWaiting Status = "waiting"
	StatusDone    Status = "done"
	StatusFailed  Status = "failed"
)

// Node is one dashboard row as Emacs serializes it, without ids or hashes.
type Node struct {
	Key          string        `json:"key"`
	Kind         string        `json:"kind"`
	Title        string        `json:"title"`
	Subtitle     string        `json:"subtitle,omitempty"`
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
	Choices      []Choice      `json:"choices,omitempty"`
	Commands     []Command     `json:"commands,omitempty"`
	Diff         bool          `json:"diff,omitempty"`
	Children     []Node        `json:"children,omitempty"`
}

// UsageWindow is one usage meter of an account.
type UsageWindow struct {
	Label string `json:"label"`
	Value Scalar `json:"value,omitzero"`
	Reset Scalar `json:"reset,omitzero"`
}

// Scalar is a JSON number or string, absent when zero.
type Scalar struct {
	Number *float64
	Text   string
}

// IsZero reports an absent scalar, for omitzero.
func (s Scalar) IsZero() bool { return s.Number == nil && s.Text == "" }

// MarshalJSON writes the number when set, else the text.
func (s Scalar) MarshalJSON() ([]byte, error) {
	if s.Number != nil {
		return json.Marshal(*s.Number)
	}
	return json.Marshal(s.Text)
}

// UnmarshalJSON accepts a number, a string or null.
func (s *Scalar) UnmarshalJSON(data []byte) error {
	*s = Scalar{}
	data = bytes.TrimSpace(data)
	switch {
	case bytes.Equal(data, []byte("null")):
		return nil
	case len(data) > 0 && data[0] == '"':
		return json.Unmarshal(data, &s.Text)
	default:
		n, err := strconv.ParseFloat(string(data), 64)
		if err != nil {
			return errors.New("bridge: scalar must be a number or a string")
		}
		s.Number = &n
		return nil
	}
}

// Command is a row command.
type Command struct {
	Name    string   `json:"name"`
	Label   string   `json:"label"`
	Input   string   `json:"input,omitempty"`
	Options []string `json:"options,omitempty"`
	Confirm bool     `json:"confirm,omitempty"`
}

// Choice is an answer an agent offers now.
type Choice struct {
	Key   string `json:"key"`
	Label string `json:"label"`
}

// Conversation is one live agent's state as Emacs publishes it.
type Conversation struct {
	ID          string      `json:"id"`
	Provider    string      `json:"provider"`
	Title       string      `json:"title"`
	Status      Status      `json:"status"`
	Persona     string      `json:"persona,omitempty"`
	Description string      `json:"description,omitempty"`
	Project     string      `json:"project,omitempty"`
	Folder      string      `json:"folder,omitempty"`
	Root        string      `json:"root"`
	Brief       string      `json:"brief,omitempty"`
	Context     *float64    `json:"context,omitempty"`
	Choices     []Choice    `json:"choices,omitempty"`
	Form        *Form       `json:"form,omitempty"`
	Queue       []QueueItem `json:"queue,omitempty"`
	QueueError  string      `json:"queueError,omitempty"`
	Controls    Controls    `json:"controls"`
	CanAttach   bool        `json:"canAttach,omitempty"`
}

// QueueItem is a remote prompt waiting for the agent.
type QueueItem struct {
	ID   string `json:"id"`
	Text string `json:"text"`
}

// Controls are the session controls a conversation offers.
type Controls struct {
	Steer    bool      `json:"steer,omitempty"`
	Actions  []string  `json:"actions"`
	Slash    []Slash   `json:"slash,omitempty"`
	Settings []Setting `json:"settings,omitempty"`
}

// Slash is a slash command the agent advertises.
type Slash struct {
	Name        string `json:"name"`
	Description string `json:"description,omitempty"`
}

// Setting is a switchable agent setting such as model or effort.
type Setting struct {
	ID      string          `json:"id"`
	Label   string          `json:"label"`
	Value   string          `json:"value"`
	Choices []SettingChoice `json:"choices"`
}

// SettingChoice is one value a setting may take.
type SettingChoice struct {
	Value string `json:"value"`
	Name  string `json:"name"`
}

// Form is a question form the agent waits on.
type Form struct {
	ID         string  `json:"id"`
	Message    string  `json:"message"`
	Answerable bool    `json:"answerable,omitempty"`
	Fields     []Field `json:"fields"`
}

// Field is one question of a form.
type Field struct {
	Key         string   `json:"key"`
	Type        string   `json:"type"`
	Title       string   `json:"title"`
	Description string   `json:"description,omitempty"`
	Required    bool     `json:"required,omitempty"`
	Options     []Option `json:"options,omitempty"`
	Other       string   `json:"other,omitempty"`
}

// Option is one choice of a single or multi field.
type Option struct {
	Value       string `json:"value"`
	Title       string `json:"title"`
	Description string `json:"description,omitempty"`
}

// EventType names an agent event.
type EventType string

const (
	EventPrompt EventType = "prompt"
	EventText   EventType = "text"
	EventTool   EventType = "tool"
	EventEnd    EventType = "end"
	EventError  EventType = "error"
)

// Event is the params of agent.event, one entry of overlook-agent-event-functions.
type Event struct {
	Conversation string    `json:"conversation"`
	At           time.Time `json:"at"`
	Type         EventType `json:"type"`
	Text         string    `json:"text,omitempty"`
	ID           string    `json:"id,omitempty"`
	Title        string    `json:"title,omitempty"`
	Status       string    `json:"status,omitempty"`
	Kind         string    `json:"kind,omitempty"`
	Diffs        []Diff    `json:"diffs,omitempty"`
	Output       string    `json:"output,omitempty"`
	Images       []Image   `json:"images,omitempty"`
}

// Diff is one file edit of a tool call.
type Diff struct {
	File string `json:"file"`
	Old  string `json:"old"`
	New  string `json:"new"`
}

// Image is an image by absolute file path or by base64 data.
type Image struct {
	File string `json:"file,omitempty"`
	Data string `json:"data,omitempty"`
	MIME string `json:"mime,omitempty"`
}

// HelloParams opens a connection.
type HelloParams struct {
	Protocol int    `json:"protocol"`
	Epoch    string `json:"epoch"`
	Emacs    string `json:"emacs"`
	PID      int    `json:"pid"`
	Lost     int    `json:"lost,omitempty"`
}

// HelloResult accepts a connection.
type HelloResult struct {
	Protocol        int    `json:"protocol"`
	Daemon          string `json:"daemon"`
	HistoryEpoch    string `json:"historyEpoch"`
	MaxMessageBytes int    `json:"maxMessageBytes"`
}

// SyncParams replaces all published state.
type SyncParams struct {
	Dashboard     []Node         `json:"dashboard"`
	Conversations []Conversation `json:"conversations"`
}

// DashboardSetParams replaces the dashboard tree.
type DashboardSetParams struct {
	Sections []Node `json:"sections"`
}

// ConversationSetParams creates or replaces one conversation.
type ConversationSetParams struct {
	Conversation Conversation `json:"conversation"`
}

// ConversationParams names a conversation; used by remove, retry, earlier and seen.
type ConversationParams struct {
	Conversation string `json:"conversation"`
}

// PromptParams sends or queues a prompt.
type PromptParams struct {
	Conversation string `json:"conversation"`
	Text         string `json:"text"`
}

// Delivery tells whether a prompt went to the agent or into the queue.
type Delivery string

const (
	DeliverySent   Delivery = "sent"
	DeliveryQueued Delivery = "queued"
)

// PromptResult is the outcome of conversation.prompt.
type PromptResult struct {
	Delivery Delivery `json:"delivery"`
	QueueID  string   `json:"queueId,omitempty"`
}

// UnqueueParams withdraws a queued prompt.
type UnqueueParams struct {
	Conversation string `json:"conversation"`
	QueueID      string `json:"queueId"`
}

// ActionParams runs a session action.
type ActionParams struct {
	Conversation string   `json:"conversation"`
	Action       string   `json:"action"`
	Text         string   `json:"text,omitempty"`
	Confirmed    []string `json:"confirmed,omitempty"`
}

// Outcome distinguishes a finished operation from one asking to confirm.
type Outcome string

const (
	OutcomeDone    Outcome = "done"
	OutcomeConfirm Outcome = "confirm"
)

// ActionOutcome is the result of conversation.action.
type ActionOutcome struct {
	Outcome      Outcome `json:"outcome"`
	Conversation string  `json:"conversation,omitempty"`
	Closed       bool    `json:"closed,omitempty"`
	Question     string  `json:"question,omitempty"`
}

// ChooseParams gives an offered choice.
type ChooseParams struct {
	Conversation string `json:"conversation"`
	Key          string `json:"key"`
}

// AnswerParams answers or declines a form.
type AnswerParams struct {
	Conversation string          `json:"conversation"`
	Form         string          `json:"form"`
	Action       string          `json:"action"`
	Values       json.RawMessage `json:"values,omitempty"`
}

// AttachParams hands an uploaded file to the agent.
type AttachParams struct {
	Conversation string `json:"conversation"`
	Path         string `json:"path"`
	Name         string `json:"name"`
}

// AttachResult is the text naming the attached file.
type AttachResult struct {
	Text string `json:"text"`
}

// EarlierResult is the fallback shown when no activity is retained.
type EarlierResult struct {
	Reply      string `json:"reply"`
	Transcript string `json:"transcript"`
}

// CommandParams runs a row command, the node named by its key path.
type CommandParams struct {
	Path      []string `json:"path"`
	Name      string   `json:"name"`
	Text      string   `json:"text,omitempty"`
	Option    string   `json:"option,omitempty"`
	Confirmed []string `json:"confirmed,omitempty"`
}

// CommandOutcome is the result of node.command.
type CommandOutcome struct {
	Outcome      Outcome `json:"outcome"`
	Conversation string  `json:"conversation,omitempty"`
	Draft        string  `json:"draft,omitempty"`
	Question     string  `json:"question,omitempty"`
}

// DiffParams asks for a node's diff.
type DiffParams struct {
	Path []string `json:"path"`
}

// DiffResult is a node's unified diff.
type DiffResult struct {
	Diff string `json:"diff"`
}

// Empty is the params or result of methods that carry nothing.
type Empty struct{}

// NewParams returns a pointer to the zero params of method, or nil for an unknown method.
func NewParams(method string) any {
	switch method {
	case MethodHello:
		return new(HelloParams)
	case MethodSync:
		return new(SyncParams)
	case MethodDashboardSet:
		return new(DashboardSetParams)
	case MethodConversationSet:
		return new(ConversationSetParams)
	case MethodConversationRemove, MethodRetry, MethodEarlier, MethodSeen:
		return new(ConversationParams)
	case MethodAgentEvent:
		return new(Event)
	case MethodPrompt:
		return new(PromptParams)
	case MethodUnqueue:
		return new(UnqueueParams)
	case MethodAction:
		return new(ActionParams)
	case MethodChoose:
		return new(ChooseParams)
	case MethodAnswer:
		return new(AnswerParams)
	case MethodAttach:
		return new(AttachParams)
	case MethodCommand:
		return new(CommandParams)
	case MethodDiff:
		return new(DiffParams)
	case MethodPing, MethodResync:
		return new(Empty)
	}
	return nil
}

// NewResult returns a pointer to the zero result of method, or nil for an unknown method.
func NewResult(method string) any {
	switch method {
	case MethodHello:
		return new(HelloResult)
	case MethodPrompt:
		return new(PromptResult)
	case MethodUnqueue, MethodRetry, MethodChoose, MethodAnswer, MethodPing:
		return new(Empty)
	case MethodAction:
		return new(ActionOutcome)
	case MethodAttach:
		return new(AttachResult)
	case MethodEarlier:
		return new(EarlierResult)
	case MethodCommand:
		return new(CommandOutcome)
	case MethodDiff:
		return new(DiffResult)
	}
	return nil
}
