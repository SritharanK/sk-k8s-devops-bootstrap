package main

import (
	"bytes"
	"context"
	"encoding/json"
	"io"
	"net"
	"net/http"
	"strconv"
	"strings"
	"sync"
	"testing"
	"time"
)

type syncBuffer struct {
	mu  sync.Mutex
	buf bytes.Buffer
}

func (b *syncBuffer) Write(p []byte) (int, error) {
	b.mu.Lock()
	defer b.mu.Unlock()
	return b.buf.Write(p)
}

func (b *syncBuffer) String() string {
	b.mu.Lock()
	defer b.mu.Unlock()
	return b.buf.String()
}

func mapEnv(m map[string]string) func(string) string {
	return func(k string) string { return m[k] }
}

func freePort(t *testing.T) int {
	t.Helper()
	ln, err := (&net.ListenConfig{}).Listen(t.Context(), "tcp", "127.0.0.1:0")
	if err != nil {
		t.Fatalf("listen: %v", err)
	}
	port := ln.Addr().(*net.TCPAddr).Port
	_ = ln.Close()
	return port
}

func TestRunInvalidConfig(t *testing.T) {
	var out syncBuffer
	err := run(t.Context(), mapEnv(map[string]string{"LOG_LEVEL": "loud"}), &out)
	if err == nil || !strings.Contains(err.Error(), "invalid configuration") {
		t.Fatalf("run() error = %v, want invalid configuration", err)
	}
}

func TestRunServesAndStops(t *testing.T) {
	t.Setenv("OTEL_EXPORTER_OTLP_ENDPOINT", "")
	t.Setenv("OTEL_EXPORTER_OTLP_TRACES_ENDPOINT", "")

	port := freePort(t)
	env := mapEnv(map[string]string{
		"HTTP_ADDR":      "127.0.0.1:" + strconv.Itoa(port),
		"SHUTDOWN_DELAY": "0s",
	})
	var out syncBuffer
	ctx, cancel := context.WithCancel(t.Context())
	runDone := make(chan error, 1)
	go func() { runDone <- run(ctx, env, &out) }()

	deadline := time.Now().Add(5 * time.Second)
	for runHealthcheck(t.Context(), env) != nil {
		if time.Now().After(deadline) {
			t.Fatalf("server did not become healthy; output: %s", out.String())
		}
		time.Sleep(20 * time.Millisecond)
	}

	// Tracing is disabled, yet the access log must carry the caller's trace
	// id from the traceparent header.
	const callerTraceID = "4bf92f3577b34da6a3ce929d0e0e4736"
	req, _ := http.NewRequestWithContext(t.Context(), http.MethodGet, "http://127.0.0.1:"+strconv.Itoa(port)+"/", http.NoBody)
	req.Header.Set("traceparent", "00-"+callerTraceID+"-00f067aa0ba902b7-01")
	resp, err := http.DefaultClient.Do(req)
	if err != nil {
		t.Fatalf("GET /: %v", err)
	}
	body, _ := io.ReadAll(resp.Body)
	_ = resp.Body.Close()
	var hello map[string]string
	if err := json.Unmarshal(body, &hello); err != nil || hello["version"] != version {
		t.Errorf("GET / body = %s, want version %q", body, version)
	}

	cancel()
	select {
	case err := <-runDone:
		if err != nil {
			t.Fatalf("run() error = %v, want nil", err)
		}
	case <-time.After(5 * time.Second):
		t.Fatal("run() did not return after cancellation")
	}

	logs := out.String()
	for _, want := range []string{
		`"msg":"starting hello-api"`,
		`"version":"` + version + `"`,
		`"msg":"request"`,
		`"trace_id":"` + callerTraceID + `"`,
		`"msg":"shutdown complete"`,
	} {
		if !strings.Contains(logs, want) {
			t.Errorf("logs do not contain %s; logs:\n%s", want, logs)
		}
	}
	if err := runHealthcheck(t.Context(), env); err == nil {
		t.Error("healthcheck succeeded after shutdown, want error")
	}
}

func TestRunHealthcheckInvalidConfig(t *testing.T) {
	if err := runHealthcheck(t.Context(), mapEnv(map[string]string{"HTTP_ADDR": "nope"})); err == nil {
		t.Fatal("runHealthcheck() error = nil, want configuration error")
	}
}
