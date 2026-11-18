package api

import (
	"encoding/json"
	"net/http/httptest"
	"strings"
	"testing"

	"github.com/guiyuanju/overlook/remote/internal/usage"
)

func TestUsageEndpointValidationAndPrivateMetadata(t *testing.T) {
	ledger, err := usage.Open(usage.Options{})
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { ledger.Close() })
	handler := New(Deps{Usage: ledger}).Handler()
	for _, q := range []string{"days=0", "days=366", "days=NaN", "timezone=missing"} {
		w := httptest.NewRecorder()
		handler.ServeHTTP(w, httptest.NewRequest("GET", "/overlook/api/usage?"+q, nil))
		if w.Code != 400 {
			t.Fatalf("%s: %d %s", q, w.Code, w.Body.String())
		}
	}
	w := httptest.NewRecorder()
	handler.ServeHTTP(w, httptest.NewRequest("GET", "/overlook/api/usage?days=7&timezone=Asia%2FTokyo", nil))
	if w.Code != 200 || w.Header().Get("Cache-Control") != "no-store" {
		t.Fatalf("status=%d headers=%v", w.Code, w.Header())
	}
	var r usage.Report
	if err := json.Unmarshal(w.Body.Bytes(), &r); err != nil {
		t.Fatal(err)
	}
	if len(r.Daily) != 7 || r.Timezone != "Asia/Tokyo" || strings.Contains(w.Body.String(), "root") {
		t.Fatalf("bad report: %s", w.Body.String())
	}
}

func TestUsageDatabaseErrorIsRetryableAPIError(t *testing.T) {
	ledger, err := usage.Open(usage.Options{})
	if err != nil {
		t.Fatal(err)
	}
	ledger.Close()
	w := httptest.NewRecorder()
	New(Deps{Usage: ledger}).Handler().ServeHTTP(w, httptest.NewRequest("GET", "/overlook/api/usage?days=7", nil))
	if w.Code != 500 || !strings.Contains(w.Body.String(), "Consumption query failed") {
		t.Fatalf("database failure hidden: %d %s", w.Code, w.Body.String())
	}
}
