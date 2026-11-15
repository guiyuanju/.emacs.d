package api

import (
	"encoding/json"
	"errors"
	"net/http"

	"github.com/guiyuanju/overlook/remote/internal/bridge"
)

// Stable problem codes of api/openapi.yaml.
const (
	CodeInvalidJSON           = "invalid_json"
	CodeInvalidBody           = "invalid_body"
	CodeInvalidField          = "invalid_field"
	CodeInvalidQuery          = "invalid_query"
	CodeInvalidIdempotencyKey = "invalid_idempotency_key"
	CodeEmptyText             = "empty_text"
	CodeUnsupportedAction     = "unsupported_action"
	CodeInvalidOption         = "invalid_option"
	CodeInvalidImage          = "invalid_image"
	CodeUnauthorized          = "unauthorized"
	CodeRouteMissing          = "route_missing"
	CodeConversationMissing   = "conversation_missing"
	CodeNodeMissing           = "node_missing"
	CodeCommandMissing        = "command_missing"
	CodeImageMissing          = "image_missing"
	CodeFileMissing           = "file_missing"
	CodeDiffMissing           = "diff_missing"
	CodeMethodNotAllowed      = "method_not_allowed"
	CodeStateConflict         = "state_conflict"
	CodeHistoryExpired        = "history_expired"
	CodeAlreadySent           = "already_sent"
	CodePromptUnsupported     = "prompt_unsupported"
	CodeAttachmentUnsupported = "attachment_unsupported"
	CodeAnswerUnsupported     = "answer_unsupported"
	CodeIdempotencyConflict   = "idempotency_conflict"
	CodeProtocolMismatch      = "protocol_mismatch"
	CodeRequestTooLarge       = "request_too_large"
	CodeImageTooLarge         = "image_too_large"
	CodeUnsupportedMediaType  = "unsupported_media_type"
	CodeTooManyStreams        = "too_many_streams"
	CodeInternalError         = "internal_error"
	CodeBridgeError           = "bridge_error"
	CodeEmacsOffline          = "emacs_offline"
	CodeEmacsTimeout          = "emacs_timeout"
)

// Problem is an RFC 9457 problem details body.
type Problem struct {
	Type   string `json:"type"`
	Title  string `json:"title"`
	Status int    `json:"status"`
	Code   string `json:"code"`
	Detail string `json:"detail"`
}

// NewProblem builds a problem with the standard type URN and title.
func NewProblem(status int, code, detail string) Problem {
	title := http.StatusText(status)
	if title == "" {
		title = "Request failed"
	}
	return Problem{Type: "urn:overlook:problem:" + code, Title: title, Status: status, Code: code, Detail: detail}
}

// WriteProblem writes p as application/problem+json.
func WriteProblem(w http.ResponseWriter, p Problem) {
	w.Header().Set("Content-Type", "application/problem+json")
	w.Header().Set("Cache-Control", "no-store")
	if p.Status == http.StatusUnauthorized {
		w.Header().Set("WWW-Authenticate", "Bearer")
	}
	w.WriteHeader(p.Status)
	_ = json.NewEncoder(w).Encode(p)
}

// ProblemFromBridge maps a bridge call error per bridge-protocol.md section 6.
func ProblemFromBridge(err error) Problem {
	var be *bridge.Error
	switch {
	case errors.Is(err, bridge.ErrOffline):
		return NewProblem(http.StatusServiceUnavailable, CodeEmacsOffline, "Emacs is not connected")
	case errors.Is(err, bridge.ErrTimeout):
		return NewProblem(http.StatusGatewayTimeout, CodeEmacsTimeout, "Emacs did not answer in time; retry to check delivery")
	case errors.As(err, &be) && be.Code >= 400 && be.Code <= 599:
		code := be.Problem()
		if code == "" {
			code = CodeStateConflict
			if be.Code >= 500 {
				code = CodeInternalError
			}
		}
		return NewProblem(be.Code, code, be.Message)
	case errors.As(err, &be):
		return NewProblem(http.StatusInternalServerError, CodeBridgeError, "Emacs could not handle the request")
	}
	return NewProblem(http.StatusInternalServerError, CodeInternalError, "The request could not be completed")
}
