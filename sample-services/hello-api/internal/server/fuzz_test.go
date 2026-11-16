package server

import (
	"encoding/json"
	"net/http"
	"net/url"
	"strings"
	"testing"
)

// FuzzHelloName sends arbitrary values of the name query parameter, the only
// untrusted input of GET /, through the full handler chain, middleware
// included. For every input the service must answer with JSON, accept the
// name exactly when validateName accepts it, and return it unchanged in the
// message. The seeds run as a unit test with go test; go test -fuzz explores
// further (see the README).
func FuzzHelloName(f *testing.F) {
	for _, seed := range []string{
		"",
		"Ada",
		"  Grace  ",
		"\x00",
		"line\nbreak",
		"‮right-to-left",
		"ünïcödé ✓",
		"<script>&amp;",
		"\xff\xfe",
		"a&b=c%20d",
		strings.Repeat("x", MaxNameLength),
		strings.Repeat("x", MaxNameLength+1),
		strings.Repeat("é", MaxNameLength),
	} {
		f.Add(seed)
	}

	h := New(Options{Version: testVersion}).Handler()

	f.Fuzz(func(t *testing.T, name string) {
		rec := do(t, h, http.MethodGet, "/?"+url.Values{"name": {name}}.Encode())

		if ct := rec.Header().Get("Content-Type"); !strings.HasPrefix(ct, "application/json") {
			t.Fatalf("Content-Type = %q, want application/json", ct)
		}

		trimmed := strings.TrimSpace(name)
		valid := trimmed == "" || validateName(trimmed) == nil

		switch rec.Code {
		case http.StatusOK:
			if !valid {
				t.Fatalf("name %q was accepted, but validateName rejects it", trimmed)
			}
			var got helloResponse
			if err := json.Unmarshal(rec.Body.Bytes(), &got); err != nil {
				t.Fatalf("200 body is not JSON: %v", err)
			}
			want := "Hello from " + ServiceName
			if trimmed != "" {
				want = "Hello " + trimmed + " from " + ServiceName
			}
			if got.Message != want {
				t.Fatalf("message = %q, want %q", got.Message, want)
			}
		case http.StatusBadRequest:
			if valid {
				t.Fatalf("name %q was rejected, but validateName accepts it", trimmed)
			}
			var got errorResponse
			if err := json.Unmarshal(rec.Body.Bytes(), &got); err != nil || got.Error == "" {
				t.Fatalf("400 body has no error message: %q (%v)", rec.Body.String(), err)
			}
		default:
			t.Fatalf("status = %d, want 200 or 400", rec.Code)
		}
	})
}
