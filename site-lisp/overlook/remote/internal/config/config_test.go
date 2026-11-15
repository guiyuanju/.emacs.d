package config

import (
	"io"
	"reflect"
	"testing"
	"time"
)

func TestParse(t *testing.T) {
	tests := []struct {
		name    string
		args    []string
		want    func(Config) bool
		wantErr bool
	}{
		{"defaults", []string{"-token-file", "t"}, func(c Config) bool {
			return reflect.DeepEqual(c.Listen, []string{DefaultListen}) && c.StreamCompression && c.AutoClose == 0
		}, false},
		{"repeatable listeners", []string{"-token-file", "t", "-listen", "127.0.0.1:1", "-listen", "100.64.0.1:2"}, func(c Config) bool {
			return reflect.DeepEqual(c.Listen, []string{"127.0.0.1:1", "100.64.0.1:2"})
		}, false},
		{"tls only", []string{"-token-file", "t", "-listen-tls", ":443", "-tls-cert", "c", "-tls-key", "k"}, func(c Config) bool {
			return len(c.Listen) == 0 && len(c.ListenTLS) == 1
		}, false},
		{"auto close", []string{"-token-file", "t", "-auto-close", "120", "-stream-compression=false"}, func(c Config) bool {
			return c.AutoClose == 120*time.Minute && !c.StreamCompression
		}, false},
		{"state beside the socket", []string{"-token-file", "t", "-socket", "/x/y/b.sock"}, func(c Config) bool {
			return c.StateFile == "/x/y/state.json" && c.WebDir == "" && c.CacheDir == DefaultCacheDir() &&
				c.AdminSocket == "/x/y/admin.sock" && c.SettingsFile == "/x/y/settings.json" && c.Caffeinate == DefaultCaffeinate()
		}, false},
		{"admin, settings and keep-awake disabled", []string{"-token-file", "t", "-admin-socket", "", "-settings-file", "", "-caffeinate", ""}, func(c Config) bool {
			return c.AdminSocket == "" && c.SettingsFile == "" && c.Caffeinate == ""
		}, false},
		{"state disabled", []string{"-token-file", "t", "-state-file", "", "-cache-dir", "", "-web-dir", "w"}, func(c Config) bool {
			return c.StateFile == "" && c.CacheDir == "" && c.WebDir == "w"
		}, false},
		{"launchd sockets", []string{"-token-file", "t", "-listen", "launchd:http"}, func(c Config) bool {
			return reflect.DeepEqual(c.Listen, []string{"launchd:http"})
		}, false},
		{"auto close of a launchd socket", []string{"-token-file", "t", "-listen", "launchd:http", "-auto-close", "5"}, nil, true},
		{"missing token", nil, nil, true},
		{"tls without cert", []string{"-token-file", "t", "-listen-tls", ":443"}, nil, true},
		{"negative auto close", []string{"-token-file", "t", "-auto-close", "-1"}, nil, true},
		{"stray argument", []string{"-token-file", "t", "extra"}, nil, true},
	}
	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			c, err := Parse(tt.args, io.Discard)
			if (err != nil) != tt.wantErr {
				t.Fatalf("Parse(%v) error = %v, wantErr %v", tt.args, err, tt.wantErr)
			}
			if err == nil && !tt.want(c) {
				t.Fatalf("Parse(%v) = %+v", tt.args, c)
			}
		})
	}
}
