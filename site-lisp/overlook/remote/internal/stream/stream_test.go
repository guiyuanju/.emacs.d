package stream

import (
	"net/url"
	"testing"
)

func TestSubscriptionRoundTrip(t *testing.T) {
	tests := []struct {
		name  string
		query string
		want  Subscription
	}{
		{"dashboard empty", "dashboard=", Subscription{Dashboard: true}},
		{"dashboard known", "dashboard=ab12", Subscription{Dashboard: true, DashboardKnown: "ab12"}},
		{"conversation", "conversation=c1&after=42&known=k&epoch=e",
			Subscription{Conversation: "c1", After: 42, Known: "k", Epoch: "e"}},
		{"both", "dashboard=d&conversation=c1&after=0&known=&epoch=",
			Subscription{Dashboard: true, DashboardKnown: "d", Conversation: "c1"}},
	}
	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			q, _ := url.ParseQuery(tt.query)
			got, err := ParseSubscription(q, "")
			if err != nil || got != tt.want {
				t.Fatalf("ParseSubscription(%q) = %+v, %v; want %+v", tt.query, got, err, tt.want)
			}
			again, err := ParseSubscription(url.Values{}, got.ID())
			if err != nil || again != got {
				t.Fatalf("resume from %q = %+v, %v; want %+v", got.ID(), again, err, got)
			}
		})
	}
}

func TestSubscriptionRejects(t *testing.T) {
	for _, query := range []string{"", "conversation=c&after=-1", "conversation=c&after=x"} {
		q, _ := url.ParseQuery(query)
		if _, err := ParseSubscription(q, ""); err == nil {
			t.Errorf("ParseSubscription(%q) accepted", query)
		}
	}
}
