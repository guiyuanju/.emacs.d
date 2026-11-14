package store

import (
	"encoding/json"
	"testing"

	"github.com/guiyuanju/overlook/remote/internal/bridge"
)

func TestWireShapes(t *testing.T) {
	n := 42.5
	tests := []struct {
		name string
		v    any
		want string
	}{
		{"same placeholder", NodeRef{Same: "ab"}, `{"same":"ab"}`},
		{"node omits empty", NodeRef{Node: &Node{ID: "0123456789abcdef", Hash: "h", Kind: "group", Title: ""}},
			`{"id":"0123456789abcdef","hash":"h","kind":"group","title":""}`},
		{"window number and text", UsageWindow{Label: "5h", Value: bridge.Scalar{Number: &n}, Reset: bridge.Scalar{Text: "2h"}},
			`{"label":"5h","value":42.5,"reset":"2h"}`},
		{"window absent value", UsageWindow{Label: "7d"}, `{"label":"7d"}`},
		{"snapshot keeps empty items", ConversationSnapshot{Items: []Item{}, Conversation: Conversation{Controls: Controls{Actions: []string{"close"}}}},
			`{"epoch":"","seq":0,"known":"","emacs":"","conversation":{"id":"","provider":"","title":"","status":"","controls":{"actions":["close"]}},"items":[],"history":{"hasMore":false}}`},
	}
	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			got, err := json.Marshal(tt.v)
			if err != nil || string(got) != tt.want {
				t.Fatalf("got %s, %v; want %s", got, err, tt.want)
			}
		})
	}
}

func TestNodeRefRoundTrip(t *testing.T) {
	in := []NodeRef{{Same: "s1"}, {Node: &Node{ID: "i", Hash: "h", Kind: "project", Title: "same", Children: []NodeRef{{Same: "s2"}}}}}
	data, _ := json.Marshal(in)
	var out []NodeRef
	if err := json.Unmarshal(data, &out); err != nil {
		t.Fatal(err)
	}
	if out[0].Same != "s1" || out[1].Node == nil || out[1].Node.Title != "same" || out[1].Node.Children[0].Same != "s2" {
		t.Fatalf("round trip: %s", data)
	}
}
