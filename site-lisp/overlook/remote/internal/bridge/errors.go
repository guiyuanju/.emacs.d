package bridge

import (
	"errors"
	"fmt"
)

// Error is a JSON-RPC error; application errors carry an HTTP status as Code.
type Error struct {
	Code    int        `json:"code"`
	Message string     `json:"message"`
	Data    *ErrorData `json:"data,omitempty"`
}

// ErrorData carries the stable problem code.
type ErrorData struct {
	Problem string `json:"problem"`
}

func (e *Error) Error() string {
	if e.Data != nil {
		return fmt.Sprintf("bridge: %d %s: %s", e.Code, e.Data.Problem, e.Message)
	}
	return fmt.Sprintf("bridge: %d: %s", e.Code, e.Message)
}

// Problem returns the stable problem code, or "" when Emacs gave none.
func (e *Error) Problem() string {
	if e.Data == nil {
		return ""
	}
	return e.Data.Problem
}

// NewError builds an application error.
func NewError(status int, problem, message string) *Error {
	return &Error{Code: status, Message: message, Data: &ErrorData{Problem: problem}}
}

// Reserved JSON-RPC error codes.
const (
	CodeParseError     = -32700
	CodeInvalidRequest = -32600
	CodeMethodNotFound = -32601
	CodeInvalidParams  = -32602
	CodeInternal       = -32603
)

var (
	// ErrOffline means no Emacs is connected, or it disconnected while a call was pending.
	ErrOffline = errors.New("bridge: emacs offline")
	// ErrTimeout means Emacs did not answer within the method's timeout; the call stays pending.
	ErrTimeout = errors.New("bridge: emacs timeout")
)
