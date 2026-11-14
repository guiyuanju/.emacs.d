package api

import (
	"bytes"
	"compress/gzip"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"net/http"
	"strconv"
	"strings"

	"github.com/andybalholm/brotli"

	"github.com/guiyuanju/overlook/remote/internal/assets"
)

// compressMin is the smallest body worth compressing.
const compressMin = 512

func marshal(v any) []byte {
	var buf bytes.Buffer
	enc := json.NewEncoder(&buf)
	enc.SetEscapeHTML(false)
	_ = enc.Encode(v)
	return bytes.TrimRight(buf.Bytes(), "\n")
}

func hash(data []byte) string {
	sum := sha256.Sum256(data)
	return hex.EncodeToString(sum[:8])
}

// etagMatch reports whether an If-None-Match header names etag (weak comparison).
func etagMatch(header, etag string) bool {
	for _, part := range strings.Split(header, ",") {
		part = strings.TrimPrefix(strings.TrimSpace(part), "W/")
		if part == "*" || part == strconv.Quote(etag) || part == `"`+etag+`"` {
			return true
		}
	}
	return false
}

// notModified sets ETag and, when the client holds it, answers 304.
func notModified(w http.ResponseWriter, r *http.Request, etag string) bool {
	w.Header().Set("ETag", `"`+etag+`"`)
	w.Header().Set("Cache-Control", "private, no-cache")
	if inm := r.Header.Get("If-None-Match"); inm != "" && etagMatch(inm, etag) {
		w.WriteHeader(http.StatusNotModified)
		return true
	}
	return false
}

func writeJSON(w http.ResponseWriter, r *http.Request, status int, v any, etag string) {
	writeRaw(w, r, status, "application/json", marshal(v), etag)
}

// writeRaw writes body compressed when the client accepts it, answering 304 for a held etag.
func writeRaw(w http.ResponseWriter, r *http.Request, status int, ctype string, body []byte, etag string) {
	if etag != "" && notModified(w, r, etag) {
		return
	}
	h := w.Header()
	if h.Get("Cache-Control") == "" {
		h.Set("Cache-Control", "no-store")
	}
	h.Set("Content-Type", ctype)
	if len(body) >= compressMin {
		h.Add("Vary", "Accept-Encoding")
		switch assets.Negotiate(r.Header.Get("Accept-Encoding")) {
		case "br":
			var buf bytes.Buffer
			bw := brotli.NewWriterLevel(&buf, 5)
			_, _ = bw.Write(body)
			_ = bw.Close()
			body = buf.Bytes()
			h.Set("Content-Encoding", "br")
		case "gzip":
			var buf bytes.Buffer
			gw, _ := gzip.NewWriterLevel(&buf, gzip.DefaultCompression)
			_, _ = gw.Write(body)
			_ = gw.Close()
			body = buf.Bytes()
			h.Set("Content-Encoding", "gzip")
		}
	}
	h.Set("Content-Length", strconv.Itoa(len(body)))
	w.WriteHeader(status)
	if r.Method != http.MethodHead {
		_, _ = w.Write(body)
	}
}

func writeOutcome(w http.ResponseWriter, r *http.Request, o Outcome) {
	if o.Status == http.StatusNoContent || len(o.Body) == 0 {
		w.Header().Set("Cache-Control", "no-store")
		w.WriteHeader(o.Status)
		return
	}
	if o.ContentType == "application/problem+json" && o.Status == http.StatusUnauthorized {
		w.Header().Set("WWW-Authenticate", "Bearer")
	}
	writeRaw(w, r, o.Status, o.ContentType, o.Body, "")
}
