package api

import (
	"errors"
	"net/http"

	"github.com/guiyuanju/overlook/remote/internal/supervisor"
)

// Supervisor follows and restarts the Emacs process.
type Supervisor interface {
	Status() supervisor.Status
	Restart() error
}

func (s *Server) emacsStatus() supervisor.Status {
	if s.d.Supervisor == nil {
		return supervisor.Status{State: supervisor.Unknown}
	}
	return s.d.Supervisor.Status()
}

func (s *Server) emacs(w http.ResponseWriter, r *http.Request) {
	w.Header().Set("Cache-Control", "no-store")
	writeJSON(w, r, http.StatusOK, s.emacsStatus(), "")
}

// restartEmacs answers 202 once the restart is under way; the stream's status events follow it.
func (s *Server) restartEmacs(w http.ResponseWriter, r *http.Request) {
	if s.d.Supervisor == nil {
		WriteProblem(w, NewProblem(http.StatusConflict, CodeStateConflict, supervisor.ErrUnavailable.Error()))
		return
	}
	switch err := s.d.Supervisor.Restart(); {
	case errors.Is(err, supervisor.ErrBusy), errors.Is(err, supervisor.ErrUnavailable):
		WriteProblem(w, NewProblem(http.StatusConflict, CodeStateConflict, err.Error()))
		return
	case err != nil:
		WriteProblem(w, NewProblem(http.StatusInternalServerError, CodeInternalError, err.Error()))
		return
	}
	s.d.Log.Info("restarting emacs at the page's request")
	w.Header().Set("Cache-Control", "no-store")
	writeJSON(w, r, http.StatusAccepted, s.emacsStatus(), "")
}
