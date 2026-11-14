package api

import (
	"context"
	"encoding/json"

	"github.com/guiyuanju/overlook/remote/internal/bridge"
	"github.com/guiyuanju/overlook/remote/internal/store"
)

// Protocol is the browser API version sent in the Overlook-Protocol header.
const Protocol = "3"

// Emacs is the set of bridge calls the API makes; *bridge.Server implements it.
type Emacs interface {
	Prompt(context.Context, bridge.PromptParams) (bridge.PromptResult, error)
	Unqueue(context.Context, bridge.UnqueueParams) error
	Retry(context.Context, bridge.ConversationParams) error
	Action(context.Context, bridge.ActionParams) (bridge.ActionOutcome, error)
	Choose(context.Context, bridge.ChooseParams) error
	Answer(context.Context, bridge.AnswerParams) error
	Attach(context.Context, bridge.AttachParams) (bridge.AttachResult, error)
	Earlier(context.Context, bridge.ConversationParams) (bridge.EarlierResult, error)
	Command(context.Context, bridge.CommandParams) (bridge.CommandOutcome, error)
	Diff(context.Context, bridge.DiffParams) (bridge.DiffResult, error)
	Seen(bridge.ConversationParams) error
}

// PromptRequest is the POST …/prompts body.
type PromptRequest struct {
	Text string `json:"text"`
}

// PromptResult is the POST …/prompts response.
type PromptResult = bridge.PromptResult

// ReadRequest is the PUT …/read body.
type ReadRequest struct {
	Through int64  `json:"through"`
	Epoch   string `json:"epoch"`
}

// ReadResult is the PUT …/read response.
type ReadResult = store.ReadResult

// ActionRequest is the POST …/actions body.
type ActionRequest struct {
	Action            string   `json:"action"`
	Text              string   `json:"text,omitempty"`
	Confirmations     []string `json:"confirmations,omitempty"`
	ConfirmationToken string   `json:"confirmationToken,omitempty"`
}

// ActionResult is ActionDone or Confirm, told apart by Outcome.
type ActionResult struct {
	Outcome           bridge.Outcome `json:"outcome"`
	Conversation      string         `json:"conversation,omitempty"`
	Closed            bool           `json:"closed,omitempty"`
	Question          string         `json:"question,omitempty"`
	Confirmations     []string       `json:"confirmations,omitempty"`
	ConfirmationToken string         `json:"confirmationToken,omitempty"`
}

// ChoiceRequest is the POST …/choice body.
type ChoiceRequest struct {
	Key string `json:"key"`
}

// FormAnswer is the POST …/forms/{form} body; values pass through to Emacs.
type FormAnswer struct {
	Action string          `json:"action"`
	Values json.RawMessage `json:"values,omitempty"`
}

// AttachmentResult is the POST …/attachments response.
type AttachmentResult = bridge.AttachResult

// DiffResult is the GET /nodes/{node}/diff response.
type DiffResult = bridge.DiffResult

// CommandRequest is the POST /nodes/{node}/commands/{name} body.
type CommandRequest struct {
	Text              string   `json:"text,omitempty"`
	Option            string   `json:"option,omitempty"`
	Confirmations     []string `json:"confirmations,omitempty"`
	ConfirmationToken string   `json:"confirmationToken,omitempty"`
}

// CommandResult is CommandDone or Confirm, told apart by Outcome.
type CommandResult struct {
	Outcome           bridge.Outcome `json:"outcome"`
	Conversation      string         `json:"conversation,omitempty"`
	Draft             string         `json:"draft,omitempty"`
	Question          string         `json:"question,omitempty"`
	Confirmations     []string       `json:"confirmations,omitempty"`
	ConfirmationToken string         `json:"confirmationToken,omitempty"`
}

// Health is the GET /overlook/healthz response.
type Health struct {
	Status string            `json:"status"`
	Emacs  store.EmacsStatus `json:"emacs"`
	Daemon string            `json:"daemon,omitempty"`
}
