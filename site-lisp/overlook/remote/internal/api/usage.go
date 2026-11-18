package api

import (
	"net/http"
	"strconv"
	"time"

	"github.com/guiyuanju/overlook/remote/internal/usage"
)

func (s *Server) usage(w http.ResponseWriter, r *http.Request) {
	days := 30
	if value := r.URL.Query().Get("days"); value != "" {
		n, err := strconv.Atoi(value)
		if err != nil || n < 1 || n > 365 {
			WriteProblem(w, NewProblem(http.StatusBadRequest, CodeInvalidQuery, "days must be 1 to 365"))
			return
		}
		days = n
	}
	loc := time.Local
	if zone := r.URL.Query().Get("timezone"); zone != "" {
		var err error
		loc, err = time.LoadLocation(zone)
		if err != nil {
			WriteProblem(w, NewProblem(http.StatusBadRequest, CodeInvalidQuery, "timezone must be an IANA time zone"))
			return
		}
	}
	w.Header().Set("Cache-Control", "no-store")
	if s.d.Usage == nil {
		writeJSON(w, r, http.StatusOK, usage.Report{Warning: "Local CLI consumption collection is disabled."}, "")
		return
	}
	report, err := s.d.Usage.Report(r.Context(), time.Now(), days, loc, r.URL.Query().Get("provider"), r.URL.Query().Get("project"))
	if err != nil {
		s.d.Log.Warn("consumption query failed", "err", err)
		WriteProblem(w, NewProblem(http.StatusInternalServerError, CodeInternalError, "Consumption query failed; retry shortly."))
		return
	}
	writeJSON(w, r, http.StatusOK, report, "")
}
