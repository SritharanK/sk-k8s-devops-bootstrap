package server

import (
	"context"
	"errors"
	"io"
	"log/slog"
	"net"
	"net/http"
	"net/http/httptest"
	"strings"
	"sync/atomic"
	"testing"
	"time"
)

var discard = slog.New(slog.DiscardHandler)

func listen(t *testing.T) net.Listener {
	t.Helper()
	ln, err := (&net.ListenConfig{}).Listen(t.Context(), "tcp", "127.0.0.1:0")
	if err != nil {
		t.Fatalf("listen: %v", err)
	}
	return ln
}

func get(ctx context.Context, url string) (int, string, error) {
	req, err := http.NewRequestWithContext(ctx, http.MethodGet, url, http.NoBody)
	if err != nil {
		return 0, "", err
	}
	resp, err := http.DefaultClient.Do(req)
	if err != nil {
		return 0, "", err
	}
	defer resp.Body.Close()
	body, err := io.ReadAll(resp.Body)
	return resp.StatusCode, string(body), err
}

func TestServeCompletesInFlightRequest(t *testing.T) {
	started := make(chan struct{})
	mux := http.NewServeMux()
	mux.HandleFunc("GET /slow", func(w http.ResponseWriter, _ *http.Request) {
		close(started)
		time.Sleep(300 * time.Millisecond)
		_, _ = io.WriteString(w, "done")
	})

	ln := listen(t)
	url := "http://" + ln.Addr().String() + "/slow"
	ctx, cancel := context.WithCancel(t.Context())
	var drained atomic.Bool
	serveDone := make(chan error, 1)
	go func() {
		serveDone <- serve(ctx, NewHTTPServer(mux, discard), ln,
			DrainConfig{Delay: 0, Timeout: 5 * time.Second}, discard, func() { drained.Store(true) })
	}()

	type result struct {
		code int
		body string
		err  error
	}
	reqDone := make(chan result, 1)
	go func() {
		code, body, err := get(t.Context(), url)
		reqDone <- result{code, body, err}
	}()

	<-started
	cancel()

	if err := <-serveDone; err != nil {
		t.Fatalf("serve() error = %v, want nil", err)
	}
	if !drained.Load() {
		t.Error("beforeDrain was not called")
	}
	select {
	case r := <-reqDone:
		if r.err != nil || r.code != http.StatusOK || r.body != "done" {
			t.Fatalf("in-flight request = %d %q %v, want 200 done", r.code, r.body, r.err)
		}
	case <-time.After(5 * time.Second):
		t.Fatal("in-flight request did not complete")
	}
	if _, _, err := get(t.Context(), url); err == nil {
		t.Error("request after shutdown succeeded, want connection error")
	}
}

func TestServeShutdownTimeout(t *testing.T) {
	started := make(chan struct{})
	release := make(chan struct{})
	t.Cleanup(func() { close(release) })
	mux := http.NewServeMux()
	mux.HandleFunc("GET /stuck", func(_ http.ResponseWriter, _ *http.Request) {
		close(started)
		<-release
	})

	ln := listen(t)
	ctx, cancel := context.WithCancel(t.Context())
	serveDone := make(chan error, 1)
	go func() {
		serveDone <- serve(ctx, NewHTTPServer(mux, discard), ln,
			DrainConfig{Delay: 0, Timeout: 100 * time.Millisecond}, discard, func() {})
	}()
	go func() { _, _, _ = get(t.Context(), "http://"+ln.Addr().String()+"/stuck") }()

	<-started
	cancel()

	select {
	case err := <-serveDone:
		if err == nil || !errors.Is(err, context.DeadlineExceeded) {
			t.Fatalf("serve() error = %v, want deadline exceeded", err)
		}
	case <-time.After(5 * time.Second):
		t.Fatal("serve() did not return after the shutdown timeout")
	}
}

func TestServeListenerError(t *testing.T) {
	ln := listen(t)
	_ = ln.Close()
	err := serve(t.Context(), NewHTTPServer(http.NotFoundHandler(), discard), ln,
		DrainConfig{Timeout: time.Second}, discard, func() {})
	if err == nil || !strings.HasPrefix(err.Error(), "serve:") {
		t.Fatalf("serve() error = %v, want serve error", err)
	}
}

func TestRunFailsReadinessDuringDelay(t *testing.T) {
	s := New(Options{Logger: discard})
	ln := listen(t)
	base := "http://" + ln.Addr().String()
	ctx, cancel := context.WithCancel(t.Context())
	runDone := make(chan error, 1)
	go func() {
		runDone <- s.Run(ctx, ln, DrainConfig{Delay: time.Second, Timeout: 2 * time.Second})
	}()

	if code, _, err := get(t.Context(), base+"/readyz"); err != nil || code != http.StatusOK {
		t.Fatalf("GET /readyz before shutdown = %d, %v, want 200", code, err)
	}

	cancel()

	// During the delay the listener stays open: readiness fails while
	// liveness and normal traffic keep working.
	deadline := time.Now().Add(500 * time.Millisecond)
	for s.Ready() && time.Now().Before(deadline) {
		time.Sleep(5 * time.Millisecond)
	}
	if code, _, err := get(t.Context(), base+"/readyz"); err != nil || code != http.StatusServiceUnavailable {
		t.Errorf("GET /readyz during delay = %d, %v, want 503", code, err)
	}
	if code, _, err := get(t.Context(), base+"/healthz"); err != nil || code != http.StatusOK {
		t.Errorf("GET /healthz during delay = %d, %v, want 200", code, err)
	}
	if code, _, err := get(t.Context(), base+"/"); err != nil || code != http.StatusOK {
		t.Errorf("GET / during delay = %d, %v, want 200", code, err)
	}

	select {
	case err := <-runDone:
		if err != nil {
			t.Fatalf("Run() error = %v, want nil", err)
		}
	case <-time.After(5 * time.Second):
		t.Fatal("Run() did not return")
	}
}

func TestHealthcheck(t *testing.T) {
	port := func(ts *httptest.Server) int { return ts.Listener.Addr().(*net.TCPAddr).Port }

	healthy := httptest.NewServer(New(Options{}).Handler())
	defer healthy.Close()
	if err := Healthcheck(t.Context(), port(healthy)); err != nil {
		t.Errorf("Healthcheck(healthy) error = %v, want nil", err)
	}

	unhealthy := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, _ *http.Request) {
		w.WriteHeader(http.StatusServiceUnavailable)
	}))
	defer unhealthy.Close()
	if err := Healthcheck(t.Context(), port(unhealthy)); err == nil || !strings.Contains(err.Error(), "503") {
		t.Errorf("Healthcheck(unhealthy) error = %v, want status 503 error", err)
	}

	ln := listen(t)
	closedPort := ln.Addr().(*net.TCPAddr).Port
	_ = ln.Close()
	if err := Healthcheck(t.Context(), closedPort); err == nil {
		t.Error("Healthcheck(closed port) error = nil, want connection error")
	}
}
