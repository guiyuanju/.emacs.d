package api

import (
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"testing"

	"github.com/guiyuanju/overlook/remote/internal/supervisor"
)

type fakeSupervisor struct {
	st  supervisor.Status
	err error
}

func (f *fakeSupervisor) Status() supervisor.Status { return f.st }

func (f *fakeSupervisor) Restart() error {
	if f.err != nil {
		return f.err
	}
	f.st.State = supervisor.Restarting
	return nil
}

func TestEmacsRestart(t *testing.T) {
	e := setup(t)
	r := e.do("GET", api+"/emacs", nil)
	var got supervisor.Status
	if err := json.Unmarshal(r.body, &got); r.status != 200 || err != nil || got.State != supervisor.Unknown || got.CanRestart {
		t.Fatalf("unsupervised status %d %s", r.status, r.body)
	}
	if r := e.do("POST", api+"/emacs/restart", nil); r.status != http.StatusConflict {
		t.Fatalf("unsupervised restart %d %s", r.status, r.body)
	}

	sup := &fakeSupervisor{st: supervisor.Status{State: supervisor.Online, PID: 7, CanRestart: true}}
	srv := httptest.NewServer(New(Deps{Store: e.st, Supervisor: sup}).Handler())
	defer srv.Close()
	resp, err := http.Post(srv.URL+api+"/emacs/restart", "application/json", nil)
	if err != nil {
		t.Fatal(err)
	}
	var st supervisor.Status
	_ = json.NewDecoder(resp.Body).Decode(&st)
	resp.Body.Close()
	if resp.StatusCode != http.StatusAccepted || st.State != supervisor.Restarting {
		t.Fatalf("restart %d %+v", resp.StatusCode, st)
	}
	sup.err = supervisor.ErrBusy
	resp, err = http.Post(srv.URL+api+"/emacs/restart", "application/json", nil)
	if err != nil {
		t.Fatal(err)
	}
	resp.Body.Close()
	if resp.StatusCode != http.StatusConflict {
		t.Fatalf("busy restart %d", resp.StatusCode)
	}
}
