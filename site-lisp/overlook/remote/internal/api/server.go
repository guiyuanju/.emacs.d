// Package api serves the browser REST API of api/openapi.yaml.
package api

import (
	"context"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"log/slog"
	"mime"
	"net/http"
	"os"
	"regexp"
	"slices"
	"strconv"
	"strings"
	"time"

	"github.com/guiyuanju/overlook/remote/internal/bridge"
	"github.com/guiyuanju/overlook/remote/internal/store"
	"github.com/guiyuanju/overlook/remote/internal/stream"
)

// Request limits.
const (
	MaxJSONBody   = 1 << 20
	MaxAttachment = 20 << 20
	// requestDeadline bounds reading and writing every request but the stream.
	requestDeadline = 2 * time.Minute
)

// Deps are what the API needs; main wires them.
type Deps struct {
	Store     *store.Store
	Emacs     Emacs
	Hub       *stream.Hub
	Auth      func(http.Handler) http.Handler
	Assets    http.Handler
	Log       *slog.Logger
	Receipts  *Receipts
	Confirmer *Confirmer
	// Version is the daemon's build, reported by healthz so a deploy can tell which binary answers.
	Version string
}

// Server holds the API handlers.
type Server struct {
	d Deps
}

// New returns an API server.
func New(d Deps) *Server {
	if d.Receipts == nil {
		d.Receipts = &Receipts{}
	}
	if d.Confirmer == nil {
		d.Confirmer = NewConfirmer()
	}
	if d.Log == nil {
		d.Log = slog.New(slog.NewTextHandler(io.Discard, nil))
	}
	if d.Auth == nil {
		d.Auth = func(h http.Handler) http.Handler { return h }
	}
	return &Server{d: d}
}

var (
	hexID   = regexp.MustCompile(`^[0-9a-f]{16}$`)
	keyChar = regexp.MustCompile(`^[\x21-\x7e]{1,128}$`)
)

// Handler routes the page, the API and health.
func (s *Server) Handler() http.Handler {
	api := http.NewServeMux()
	api.HandleFunc("GET /overlook/api/dashboard", s.dashboard)
	api.HandleFunc("GET /overlook/api/stream", s.stream)
	api.HandleFunc("GET /overlook/api/conversations", s.conversations)
	api.HandleFunc("GET /overlook/api/conversations/{conversation}", s.conversation)
	api.HandleFunc("GET /overlook/api/conversations/{conversation}/history", s.history)
	api.HandleFunc("POST /overlook/api/conversations/{conversation}/prompts", s.prompt)
	api.HandleFunc("DELETE /overlook/api/conversations/{conversation}/prompts/{queueId}", s.unqueue)
	api.HandleFunc("POST /overlook/api/conversations/{conversation}/prompts/retry", s.retry)
	api.HandleFunc("PUT /overlook/api/conversations/{conversation}/read", s.read)
	api.HandleFunc("POST /overlook/api/conversations/{conversation}/actions", s.action)
	api.HandleFunc("POST /overlook/api/conversations/{conversation}/choice", s.choice)
	api.HandleFunc("POST /overlook/api/conversations/{conversation}/forms/{form}", s.form)
	api.HandleFunc("POST /overlook/api/conversations/{conversation}/attachments", s.attach)
	api.HandleFunc("GET /overlook/api/images/{image}", s.image)
	api.HandleFunc("GET /overlook/api/nodes/{node}/diff", s.diff)
	api.HandleFunc("POST /overlook/api/nodes/{node}/commands/{name}", s.command)

	mux := http.NewServeMux()
	mux.Handle("/overlook/api/", apiHeaders(s.d.Auth(routed(api))))
	mux.Handle("/overlook/healthz", apiHeaders(routed(http.HandlerFunc(s.health))))
	if s.d.Assets != nil {
		mux.Handle("/overlook/", s.d.Assets)
	}
	return s.logged(deadlines(mux))
}

// apiHeaders sets the protocol and security headers of every API response.
func apiHeaders(next http.Handler) http.Handler {
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		h := w.Header()
		h.Set("Overlook-Protocol", Protocol)
		h.Set("X-Content-Type-Options", "nosniff")
		h.Set("Referrer-Policy", "no-referrer")
		h.Set("Content-Security-Policy", "default-src 'none'; frame-ancestors 'none'")
		next.ServeHTTP(w, r)
	})
}

// deadlines bounds every request but the event stream.
func deadlines(next http.Handler) http.Handler {
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.URL.Path != "/overlook/api/stream" {
			rc := http.NewResponseController(w)
			_ = rc.SetReadDeadline(time.Now().Add(requestDeadline))
			_ = rc.SetWriteDeadline(time.Now().Add(requestDeadline))
		}
		next.ServeHTTP(w, r)
	})
}

// routed turns the mux's plain-text 404 and 405 into problems.
func routed(mux http.Handler) http.Handler {
	m, ok := mux.(*http.ServeMux)
	if !ok {
		return mux
	}
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		h, pattern := m.Handler(r)
		if pattern != "" {
			m.ServeHTTP(w, r)
			return
		}
		cw := &captureWriter{header: http.Header{}}
		h.ServeHTTP(cw, r)
		switch cw.status {
		case http.StatusMethodNotAllowed:
			w.Header().Set("Allow", cw.header.Get("Allow"))
			WriteProblem(w, NewProblem(http.StatusMethodNotAllowed, CodeMethodNotAllowed,
				r.Method+" is not allowed here; use "+cw.header.Get("Allow")))
		case http.StatusMovedPermanently, http.StatusTemporaryRedirect, http.StatusPermanentRedirect:
			h.ServeHTTP(w, r)
		default:
			WriteProblem(w, NewProblem(http.StatusNotFound, CodeRouteMissing, "No "+r.Method+" "+r.URL.Path))
		}
	})
}

type captureWriter struct {
	header http.Header
	status int
}

func (c *captureWriter) Header() http.Header         { return c.header }
func (c *captureWriter) Write(p []byte) (int, error) { return len(p), nil }
func (c *captureWriter) WriteHeader(status int) {
	if c.status == 0 {
		c.status = status
	}
}

type statusWriter struct {
	http.ResponseWriter
	status int
	bytes  int64
}

func (w *statusWriter) WriteHeader(status int) {
	if w.status == 0 {
		w.status = status
	}
	w.ResponseWriter.WriteHeader(status)
}

func (w *statusWriter) Write(p []byte) (int, error) {
	if w.status == 0 {
		w.status = http.StatusOK
	}
	n, err := w.ResponseWriter.Write(p)
	w.bytes += int64(n)
	return n, err
}

func (w *statusWriter) Unwrap() http.ResponseWriter { return w.ResponseWriter }

func (w *statusWriter) Flush() {
	if f, ok := w.ResponseWriter.(http.Flusher); ok {
		f.Flush()
	}
}

func (s *Server) logged(next http.Handler) http.Handler {
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		start := time.Now()
		sw := &statusWriter{ResponseWriter: w}
		next.ServeHTTP(sw, r)
		s.d.Log.Debug("http", "method", r.Method, "path", r.URL.Path, "status", sw.status,
			"bytes", sw.bytes, "ms", time.Since(start).Milliseconds(), "proto", r.Proto)
	})
}

func (s *Server) health(w http.ResponseWriter, r *http.Request) {
	if r.Method != http.MethodGet && r.Method != http.MethodHead {
		w.Header().Set("Allow", "GET, HEAD")
		WriteProblem(w, NewProblem(http.StatusMethodNotAllowed, CodeMethodNotAllowed, "Use GET"))
		return
	}
	emacs := store.EmacsOffline
	if s.d.Store != nil {
		emacs = s.d.Store.Emacs()
	}
	w.Header().Set("Cache-Control", "no-store")
	writeJSON(w, r, http.StatusOK, Health{Status: "ok", Emacs: emacs, Daemon: s.d.Version}, "")
}

func (s *Server) dashboard(w http.ResponseWriter, r *http.Request) {
	d := s.d.Store.Dashboard(r.URL.Query().Get("known"))
	writeJSON(w, r, http.StatusOK, d, d.Known)
}

func (s *Server) stream(w http.ResponseWriter, r *http.Request) {
	sub, err := stream.ParseSubscription(r.URL.Query(), r.Header.Get("Last-Event-ID"))
	if err != nil {
		WriteProblem(w, NewProblem(http.StatusBadRequest, CodeInvalidQuery, err.Error()))
		return
	}
	if sub.Conversation != "" {
		if _, err := s.d.Store.Conversation(sub.Conversation); err != nil {
			WriteProblem(w, storeProblem(err))
			return
		}
	}
	switch err := s.d.Hub.Serve(r.Context(), w, r, sub); {
	case errors.Is(err, stream.ErrTooManyStreams):
		WriteProblem(w, NewProblem(http.StatusTooManyRequests, CodeTooManyStreams, "Too many open streams"))
	case errors.Is(err, stream.ErrClosed):
		WriteProblem(w, NewProblem(http.StatusServiceUnavailable, CodeInternalError, "The server is shutting down"))
	}
}

func (s *Server) conversations(w http.ResponseWriter, r *http.Request) {
	list := s.d.Store.Conversations()
	body := marshal(list)
	writeRaw(w, r, http.StatusOK, "application/json", body, hash(body))
}

func (s *Server) conversation(w http.ResponseWriter, r *http.Request) {
	snap, err := s.d.Store.Snapshot(r.PathValue("conversation"))
	if err != nil {
		WriteProblem(w, storeProblem(err))
		return
	}
	etag := fmt.Sprintf("%s.%d.%s", snap.Epoch, snap.Seq, snap.Known)
	if notModified(w, r, etag) {
		return
	}
	if len(snap.Items) == 0 {
		EarlierFunc(s.d.Emacs, s.d.Store)(r.Context(), &snap)
	}
	writeJSON(w, r, http.StatusOK, snap, etag)
}

// EarlierFunc fills a snapshot without items with the reply and transcript from Emacs, within 2 s.
func EarlierFunc(emacs Emacs, st *store.Store) stream.EarlierFunc {
	return func(ctx context.Context, snap *store.ConversationSnapshot) {
		if emacs == nil || st.Emacs() != store.EmacsOnline {
			return
		}
		ctx, cancel := context.WithTimeout(ctx, bridge.Timeout(bridge.MethodEarlier))
		defer cancel()
		res, err := emacs.Earlier(ctx, bridge.ConversationParams{Conversation: snap.Conversation.ID})
		if err == nil {
			snap.Earlier = &res
		}
	}
}

func (s *Server) history(w http.ResponseWriter, r *http.Request) {
	q := r.URL.Query()
	before, err := strconv.ParseInt(q.Get("before"), 10, 64)
	if err != nil || before < 1 {
		WriteProblem(w, NewProblem(http.StatusBadRequest, CodeInvalidQuery, "before must be an item id"))
		return
	}
	limit := store.PageSize
	if v := q.Get("limit"); v != "" {
		if limit, err = strconv.Atoi(v); err != nil || limit < 1 || limit > store.MaxPageSize {
			WriteProblem(w, NewProblem(http.StatusBadRequest, CodeInvalidQuery, "limit must be 1 to 100"))
			return
		}
	}
	epoch := q.Get("epoch")
	if epoch == "" {
		WriteProblem(w, NewProblem(http.StatusBadRequest, CodeInvalidQuery, "epoch is required"))
		return
	}
	page, err := s.d.Store.History(r.PathValue("conversation"), before, limit, epoch)
	if err != nil {
		WriteProblem(w, storeProblem(err))
		return
	}
	w.Header().Set("Cache-Control", "no-store")
	writeJSON(w, r, http.StatusOK, page, "")
}

func storeProblem(err error) Problem {
	switch {
	case errors.Is(err, store.ErrConversationMissing):
		return NewProblem(http.StatusNotFound, CodeConversationMissing, "That conversation is gone")
	case errors.Is(err, store.ErrNodeMissing):
		return NewProblem(http.StatusNotFound, CodeNodeMissing, "That row is gone")
	case errors.Is(err, store.ErrImageMissing):
		return NewProblem(http.StatusNotFound, CodeImageMissing, "That image is gone")
	case errors.Is(err, store.ErrHistoryExpired):
		return NewProblem(http.StatusConflict, CodeHistoryExpired, "That history is no longer retained")
	}
	return NewProblem(http.StatusInternalServerError, CodeInternalError, "The request could not be completed")
}

// idempotencyKey validates the optional Idempotency-Key header.
func idempotencyKey(r *http.Request) (string, *Problem) {
	key := r.Header.Get("Idempotency-Key")
	if key == "" {
		if _, present := r.Header["Idempotency-Key"]; present {
			p := NewProblem(http.StatusBadRequest, CodeInvalidIdempotencyKey, "Idempotency-Key must not be empty")
			return "", &p
		}
		return "", nil
	}
	if !keyChar.MatchString(key) {
		p := NewProblem(http.StatusBadRequest, CodeInvalidIdempotencyKey, "Idempotency-Key must be 1 to 128 visible ASCII characters")
		return "", &p
	}
	return key, nil
}

// decode reads a JSON body into v; strict rejects unknown fields.
func decode(w http.ResponseWriter, r *http.Request, v any, strict bool) *Problem {
	r.Body = http.MaxBytesReader(w, r.Body, MaxJSONBody)
	dec := json.NewDecoder(r.Body)
	if strict {
		dec.DisallowUnknownFields()
	}
	fail := func(status int, code, detail string) *Problem {
		p := NewProblem(status, code, detail)
		return &p
	}
	if err := dec.Decode(v); err != nil {
		var mbe *http.MaxBytesError
		var te *json.UnmarshalTypeError
		switch {
		case errors.As(err, &mbe):
			return fail(http.StatusRequestEntityTooLarge, CodeRequestTooLarge, "The request body is too large")
		case errors.As(err, &te):
			return fail(http.StatusBadRequest, CodeInvalidField, "Field "+te.Field+" has the wrong type")
		case strings.HasPrefix(err.Error(), "json: unknown field"):
			return fail(http.StatusBadRequest, CodeInvalidBody, strings.TrimPrefix(err.Error(), "json: "))
		default:
			return fail(http.StatusBadRequest, CodeInvalidJSON, "The body is not valid JSON")
		}
	}
	if _, err := dec.Token(); !errors.Is(err, io.EOF) {
		return fail(http.StatusBadRequest, CodeInvalidJSON, "The body has data after the JSON value")
	}
	return nil
}

func required(name string) *Problem {
	p := NewProblem(http.StatusBadRequest, CodeInvalidField, name+" is required")
	return &p
}

// signature identifies a write's payload for idempotency, without confirmation fields.
func signature(r *http.Request, payload any) string {
	data, _ := json.Marshal(payload)
	return hash(append([]byte(r.Method+" "+r.URL.Path+"\n"), data...))
}

// write runs fn under the receipt for key, waiting at most method's bridge timeout.
func (s *Server) write(w http.ResponseWriter, r *http.Request, key, sig, method string, fn func(context.Context) Outcome) {
	ctx, cancel := context.WithTimeout(r.Context(), bridge.Timeout(method))
	defer cancel()
	writeOutcome(w, r, s.d.Receipts.Do(ctx, key, sig, fn))
}

func bridgeOutcome(err error) Outcome {
	return problemOutcome(ProblemFromBridge(err))
}

func storeOutcome(err error) Outcome {
	return problemOutcome(storeProblem(err))
}

func jsonOutcome(v any, keep bool) Outcome {
	return Outcome{Status: http.StatusOK, ContentType: "application/json", Body: marshal(v), Keep: keep}
}

var noContent = Outcome{Status: http.StatusNoContent, Keep: true}

func (s *Server) prompt(w http.ResponseWriter, r *http.Request) {
	id := r.PathValue("conversation")
	key, p := idempotencyKey(r)
	var req struct {
		Text *string `json:"text"`
	}
	if p == nil {
		p = decode(w, r, &req, true)
	}
	if p == nil && req.Text == nil {
		p = required("text")
	}
	if p != nil {
		WriteProblem(w, *p)
		return
	}
	text := strings.TrimSpace(*req.Text)
	if text == "" {
		WriteProblem(w, NewProblem(http.StatusBadRequest, CodeEmptyText, "Write something first"))
		return
	}
	s.write(w, r, key, signature(r, text), bridge.MethodPrompt, func(ctx context.Context) Outcome {
		if _, err := s.d.Store.Conversation(id); err != nil {
			return storeOutcome(err)
		}
		res, err := s.d.Emacs.Prompt(ctx, bridge.PromptParams{Conversation: id, Text: text})
		if err != nil {
			return bridgeOutcome(err)
		}
		return jsonOutcome(res, true)
	})
}

func (s *Server) unqueue(w http.ResponseWriter, r *http.Request) {
	id, queueID := r.PathValue("conversation"), r.PathValue("queueId")
	key, p := idempotencyKey(r)
	if p != nil {
		WriteProblem(w, *p)
		return
	}
	s.write(w, r, key, signature(r, nil), bridge.MethodUnqueue, func(ctx context.Context) Outcome {
		if _, err := s.d.Store.Conversation(id); err != nil {
			return storeOutcome(err)
		}
		if err := s.d.Emacs.Unqueue(ctx, bridge.UnqueueParams{Conversation: id, QueueID: queueID}); err != nil {
			return bridgeOutcome(err)
		}
		return noContent
	})
}

func (s *Server) retry(w http.ResponseWriter, r *http.Request) {
	id := r.PathValue("conversation")
	key, p := idempotencyKey(r)
	if p != nil {
		WriteProblem(w, *p)
		return
	}
	s.write(w, r, key, signature(r, nil), bridge.MethodRetry, func(ctx context.Context) Outcome {
		if _, err := s.d.Store.Conversation(id); err != nil {
			return storeOutcome(err)
		}
		if err := s.d.Emacs.Retry(ctx, bridge.ConversationParams{Conversation: id}); err != nil {
			return bridgeOutcome(err)
		}
		return noContent
	})
}

func (s *Server) read(w http.ResponseWriter, r *http.Request) {
	id := r.PathValue("conversation")
	var req struct {
		Through *int64  `json:"through"`
		Epoch   *string `json:"epoch"`
	}
	p := decode(w, r, &req, true)
	switch {
	case p != nil:
	case req.Through == nil || *req.Through < 0:
		p = required("through ≥ 0")
	case req.Epoch == nil || *req.Epoch == "":
		p = required("epoch")
	}
	if p != nil {
		WriteProblem(w, *p)
		return
	}
	res, caughtUp, err := s.d.Store.Read(id, *req.Through, *req.Epoch)
	if err != nil {
		WriteProblem(w, storeProblem(err))
		return
	}
	if caughtUp && s.d.Emacs != nil {
		_ = s.d.Emacs.Seen(bridge.ConversationParams{Conversation: id})
	}
	w.Header().Set("Cache-Control", "no-store")
	writeJSON(w, r, http.StatusOK, res, "")
}

// confirmed returns the questions to forward: the client's when its token is valid, else none.
func (s *Server) confirmed(token string, questions []string, target, op, input, state string) []string {
	if len(questions) > 0 && s.d.Confirmer.Valid(token, target, op, input, state, questions) {
		return questions
	}
	return []string{}
}

func (s *Server) action(w http.ResponseWriter, r *http.Request) {
	id := r.PathValue("conversation")
	key, p := idempotencyKey(r)
	var req ActionRequest
	if p == nil {
		p = decode(w, r, &req, false)
	}
	if p == nil && req.Action == "" {
		p = required("action")
	}
	if p != nil {
		WriteProblem(w, *p)
		return
	}
	text := strings.TrimSpace(req.Text)
	sig := signature(r, ActionRequest{Action: req.Action, Text: text})
	s.write(w, r, key, sig, bridge.MethodAction, func(ctx context.Context) Outcome {
		st, err := s.d.Store.Conversation(id)
		if err != nil {
			return storeOutcome(err)
		}
		setting := slices.ContainsFunc(st.Controls.Settings, func(x bridge.Setting) bool { return x.ID == req.Action })
		switch {
		case req.Action == "steer" && !st.Controls.Steer,
			req.Action != "steer" && req.Action != "close" && !slices.Contains(st.Controls.Actions, req.Action):
			return problemOutcome(NewProblem(http.StatusBadRequest, CodeUnsupportedAction, "This conversation does not offer "+req.Action))
		case (req.Action == "steer" || setting) && text == "":
			return problemOutcome(NewProblem(http.StatusBadRequest, CodeEmptyText, "Choose or write a value first"))
		}
		state, err := s.d.Store.ConversationConfirmState(id)
		if err != nil {
			return storeOutcome(err)
		}
		op := "action:" + req.Action
		confirmed := s.confirmed(req.ConfirmationToken, req.Confirmations, id, op, text, state)
		out, err := s.d.Emacs.Action(ctx, bridge.ActionParams{Conversation: id, Action: req.Action, Text: text, Confirmed: confirmed})
		if err != nil {
			return bridgeOutcome(err)
		}
		if out.Outcome == bridge.OutcomeConfirm {
			qs := append(slices.Clone(confirmed), out.Question)
			return jsonOutcome(ActionResult{Outcome: out.Outcome, Question: out.Question, Confirmations: qs,
				ConfirmationToken: s.d.Confirmer.Token(id, op, text, state, qs)}, false)
		}
		return jsonOutcome(ActionResult{Outcome: bridge.OutcomeDone, Conversation: out.Conversation, Closed: out.Closed}, true)
	})
}

func (s *Server) choice(w http.ResponseWriter, r *http.Request) {
	id := r.PathValue("conversation")
	key, p := idempotencyKey(r)
	var req struct {
		Key *string `json:"key"`
	}
	if p == nil {
		p = decode(w, r, &req, true)
	}
	if p == nil && (req.Key == nil || *req.Key == "") {
		p = required("key")
	}
	if p != nil {
		WriteProblem(w, *p)
		return
	}
	choice := *req.Key
	s.write(w, r, key, signature(r, choice), bridge.MethodChoose, func(ctx context.Context) Outcome {
		if _, err := s.d.Store.Conversation(id); err != nil {
			return storeOutcome(err)
		}
		if err := s.d.Emacs.Choose(ctx, bridge.ChooseParams{Conversation: id, Key: choice}); err != nil {
			return bridgeOutcome(err)
		}
		return noContent
	})
}

func (s *Server) form(w http.ResponseWriter, r *http.Request) {
	id, formID := r.PathValue("conversation"), r.PathValue("form")
	key, p := idempotencyKey(r)
	var req FormAnswer
	if p == nil {
		p = decode(w, r, &req, true)
	}
	if p == nil && req.Action != "accept" && req.Action != "decline" {
		p = required("action accept or decline")
	}
	if p == nil && len(req.Values) > 0 && !strings.HasPrefix(strings.TrimSpace(string(req.Values)), "{") {
		p = required("values as an object")
	}
	if p != nil {
		WriteProblem(w, *p)
		return
	}
	s.write(w, r, key, signature(r, req), bridge.MethodAnswer, func(ctx context.Context) Outcome {
		st, err := s.d.Store.Conversation(id)
		if err != nil {
			return storeOutcome(err)
		}
		if st.Form == nil || st.Form.ID != formID {
			return problemOutcome(NewProblem(http.StatusConflict, CodeStateConflict, "That question is no longer asked"))
		}
		values := req.Values
		if len(values) == 0 {
			values = json.RawMessage("{}")
		}
		if err := s.d.Emacs.Answer(ctx, bridge.AnswerParams{Conversation: id, Form: formID, Action: req.Action, Values: values}); err != nil {
			return bridgeOutcome(err)
		}
		return noContent
	})
}

func (s *Server) attach(w http.ResponseWriter, r *http.Request) {
	id := r.PathValue("conversation")
	key, p := idempotencyKey(r)
	if p != nil {
		WriteProblem(w, *p)
		return
	}
	ctype, _, _ := mime.ParseMediaType(r.Header.Get("Content-Type"))
	if _, ok := store.ImageTypes[ctype]; !ok {
		WriteProblem(w, NewProblem(http.StatusUnsupportedMediaType, CodeUnsupportedMediaType, "Send a PNG, JPEG, GIF or WebP image"))
		return
	}
	data, err := io.ReadAll(http.MaxBytesReader(w, r.Body, MaxAttachment))
	if err != nil {
		var mbe *http.MaxBytesError
		if errors.As(err, &mbe) {
			WriteProblem(w, NewProblem(http.StatusRequestEntityTooLarge, CodeImageTooLarge, "Images may be at most 20 MiB"))
			return
		}
		WriteProblem(w, NewProblem(http.StatusBadRequest, CodeInvalidImage, "The upload was cut short"))
		return
	}
	if store.SniffImage(data) != ctype {
		WriteProblem(w, NewProblem(http.StatusBadRequest, CodeInvalidImage, "The bytes are not a "+ctype+" image"))
		return
	}
	sum := sha256.Sum256(data)
	sig := signature(r, ctype+" "+hex.EncodeToString(sum[:]))
	s.write(w, r, key, sig, bridge.MethodAttach, func(ctx context.Context) Outcome {
		st, err := s.d.Store.Conversation(id)
		if err != nil {
			return storeOutcome(err)
		}
		if !st.CanAttach {
			return problemOutcome(NewProblem(http.StatusConflict, CodeAttachmentUnsupported, "This conversation cannot take files"))
		}
		path, name, err := s.d.Store.SaveUpload(data, ctype)
		if err != nil {
			s.d.Log.Error("save upload", "err", err)
			return problemOutcome(NewProblem(http.StatusInternalServerError, CodeInternalError, "The upload could not be saved"))
		}
		defer os.Remove(path)
		res, err := s.d.Emacs.Attach(ctx, bridge.AttachParams{Conversation: id, Path: path, Name: name})
		if err != nil {
			return bridgeOutcome(err)
		}
		return jsonOutcome(res, true)
	})
}

func (s *Server) image(w http.ResponseWriter, r *http.Request) {
	id := r.PathValue("image")
	if !hexID.MatchString(id) {
		WriteProblem(w, storeProblem(store.ErrImageMissing))
		return
	}
	img, err := s.d.Store.Image(id)
	if err != nil {
		WriteProblem(w, storeProblem(err))
		return
	}
	f, err := img.Open()
	if err != nil {
		WriteProblem(w, storeProblem(store.ErrImageMissing))
		return
	}
	defer f.Close()
	h := w.Header()
	h.Set("Content-Type", img.MIME)
	h.Set("Cache-Control", "private, max-age=31536000, immutable")
	h.Set("ETag", `"`+id+`"`)
	http.ServeContent(w, r, "", time.Time{}, f)
}

func (s *Server) diff(w http.ResponseWriter, r *http.Request) {
	id := r.PathValue("node")
	if !hexID.MatchString(id) {
		WriteProblem(w, storeProblem(store.ErrNodeMissing))
		return
	}
	path, node, err := s.d.Store.NodeTarget(id)
	if err != nil {
		WriteProblem(w, storeProblem(err))
		return
	}
	if !node.Diff {
		WriteProblem(w, NewProblem(http.StatusNotFound, CodeDiffMissing, "This row has no diff"))
		return
	}
	ctx, cancel := context.WithTimeout(r.Context(), bridge.Timeout(bridge.MethodDiff))
	defer cancel()
	res, err := s.d.Emacs.Diff(ctx, bridge.DiffParams{Path: path})
	if err != nil {
		WriteProblem(w, ProblemFromBridge(err))
		return
	}
	res.Diff = store.Cut(res.Diff, store.DiffChars)
	w.Header().Set("Cache-Control", "no-store")
	writeJSON(w, r, http.StatusOK, res, "")
}

func (s *Server) command(w http.ResponseWriter, r *http.Request) {
	id, name := r.PathValue("node"), r.PathValue("name")
	key, p := idempotencyKey(r)
	var req CommandRequest
	if p == nil {
		p = decode(w, r, &req, false)
	}
	if p != nil {
		WriteProblem(w, *p)
		return
	}
	text := strings.TrimSpace(req.Text)
	sig := signature(r, CommandRequest{Text: text, Option: req.Option})
	s.write(w, r, key, sig, bridge.MethodCommand, func(ctx context.Context) Outcome {
		if !hexID.MatchString(id) {
			return storeOutcome(store.ErrNodeMissing)
		}
		path, node, err := s.d.Store.NodeTarget(id)
		if err != nil {
			return storeOutcome(err)
		}
		i := slices.IndexFunc(node.Commands, func(c bridge.Command) bool { return c.Name == name })
		if i < 0 {
			return problemOutcome(NewProblem(http.StatusNotFound, CodeCommandMissing, "This row has no command "+name))
		}
		cmd := node.Commands[i]
		switch {
		case cmd.Input != "" && text == "":
			return problemOutcome(NewProblem(http.StatusBadRequest, CodeEmptyText, "Write "+cmd.Input+" first"))
		case len(cmd.Options) > 0 && !slices.Contains(cmd.Options, req.Option):
			return problemOutcome(NewProblem(http.StatusBadRequest, CodeInvalidOption, "Pick one of the offered options"))
		}
		state, err := s.d.Store.NodeConfirmState(id)
		if err != nil {
			return storeOutcome(err)
		}
		op, input := "command:"+name, text+"\x00"+req.Option
		confirmed := s.confirmed(req.ConfirmationToken, req.Confirmations, id, op, input, state)
		out, err := s.d.Emacs.Command(ctx, bridge.CommandParams{Path: path, Name: name, Text: text, Option: req.Option, Confirmed: confirmed})
		if err != nil {
			return bridgeOutcome(err)
		}
		if out.Outcome == bridge.OutcomeConfirm {
			qs := append(slices.Clone(confirmed), out.Question)
			return jsonOutcome(CommandResult{Outcome: out.Outcome, Question: out.Question, Confirmations: qs,
				ConfirmationToken: s.d.Confirmer.Token(id, op, input, state, qs)}, false)
		}
		return jsonOutcome(CommandResult{Outcome: bridge.OutcomeDone, Conversation: out.Conversation, Draft: out.Draft}, true)
	})
}
