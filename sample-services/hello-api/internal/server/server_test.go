package server

import (
	"bufio"
	"bytes"
	"context"
	"encoding/json"
	"io"
	"log/slog"
	"net/http"
	"net/http/httptest"
	"runtime"
	"strings"
	"sync"
	"testing"

	sdktrace "go.opentelemetry.io/otel/sdk/trace"
	"go.opentelemetry.io/otel/sdk/trace/tracetest"

	"github.com/SritharanK/sk-k8s-devops-bootstrap/sample-services/hello-api/internal/telemetry"
)

const testVersion = "1.2.3"

// Trace and span id of an incoming W3C traceparent header.
const (
	parentTraceID = "4bf92f3577b34da6a3ce929d0e0e4736"
	parentSpanID  = "00f067aa0ba902b7"
)

// tracedLogger returns a debug-level JSON logger wrapped like the one in
// main, so that records with a span context carry trace_id and span_id.
func tracedLogger(w io.Writer) *slog.Logger {
	return slog.New(telemetry.NewLogHandler(slog.NewJSONHandler(w, &slog.HandlerOptions{Level: slog.LevelDebug})))
}

// syncBuffer is a bytes.Buffer that is safe for concurrent writers.
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

func do(t *testing.T, h http.Handler, method, target string) *httptest.ResponseRecorder {
	t.Helper()
	req := httptest.NewRequestWithContext(t.Context(), method, target, http.NoBody)
	rec := httptest.NewRecorder()
	h.ServeHTTP(rec, req)
	return rec
}

func TestHello(t *testing.T) {
	s := New(Options{Version: testVersion})
	rec := do(t, s.Handler(), http.MethodGet, "/")

	if rec.Code != http.StatusOK {
		t.Fatalf("status = %d, want 200", rec.Code)
	}
	if ct := rec.Header().Get("Content-Type"); ct != "application/json" {
		t.Errorf("Content-Type = %q, want application/json", ct)
	}
	var got helloResponse
	if err := json.Unmarshal(rec.Body.Bytes(), &got); err != nil {
		t.Fatalf("decode body %q: %v", rec.Body.String(), err)
	}
	want := helloResponse{Service: "hello-api", Version: testVersion, Message: "Hello from hello-api"}
	if got != want {
		t.Errorf("body = %+v, want %+v", got, want)
	}
}

func TestHelloName(t *testing.T) {
	tests := []struct {
		name        string
		query       string
		wantStatus  int
		wantMessage string
		wantError   string
	}{
		{"plain name", "?name=Alice", http.StatusOK, "Hello Alice from hello-api", ""},
		{"trimmed name", "?name=%20Bob%20", http.StatusOK, "Hello Bob from hello-api", ""},
		{"unicode name", "?name=Zo%C3%AB", http.StatusOK, "Hello Zoë from hello-api", ""},
		{"markup is returned as data", "?name=%3Cb%3E", http.StatusOK, "Hello <b> from hello-api", ""},
		{"empty name uses default", "?name=", http.StatusOK, "Hello from hello-api", ""},
		{"maximum length", "?name=" + strings.Repeat("a", MaxNameLength), http.StatusOK, "Hello " + strings.Repeat("a", MaxNameLength) + " from hello-api", ""},
		{"too long", "?name=" + strings.Repeat("a", MaxNameLength+1), http.StatusBadRequest, "", "at most 64 characters"},
		{"control character", "?name=a%0Ab", http.StatusBadRequest, "", "control characters"},
		{"invalid UTF-8", "?name=%FF", http.StatusBadRequest, "", "valid UTF-8"},
	}
	s := New(Options{Version: testVersion})
	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			rec := do(t, s.Handler(), http.MethodGet, "/"+tt.query)
			if rec.Code != tt.wantStatus {
				t.Fatalf("status = %d, want %d (body %q)", rec.Code, tt.wantStatus, rec.Body.String())
			}
			if ct := rec.Header().Get("Content-Type"); ct != "application/json" {
				t.Errorf("Content-Type = %q, want application/json", ct)
			}
			if tt.wantStatus == http.StatusOK {
				var got helloResponse
				if err := json.Unmarshal(rec.Body.Bytes(), &got); err != nil {
					t.Fatalf("decode body: %v", err)
				}
				if got.Message != tt.wantMessage {
					t.Errorf("message = %q, want %q", got.Message, tt.wantMessage)
				}
				return
			}
			var got errorResponse
			if err := json.Unmarshal(rec.Body.Bytes(), &got); err != nil {
				t.Fatalf("decode error body: %v", err)
			}
			if !strings.Contains(got.Error, tt.wantError) {
				t.Errorf("error = %q, want it to contain %q", got.Error, tt.wantError)
			}
		})
	}
}

func TestHealthz(t *testing.T) {
	s := New(Options{})
	for _, shuttingDown := range []bool{false, true} {
		if shuttingDown {
			s.MarkShuttingDown()
		}
		rec := do(t, s.Handler(), http.MethodGet, "/healthz")
		if rec.Code != http.StatusOK || strings.TrimSpace(rec.Body.String()) != "ok" {
			t.Errorf("shuttingDown=%v: GET /healthz = %d %q, want 200 ok", shuttingDown, rec.Code, rec.Body.String())
		}
	}
}

func TestReadyz(t *testing.T) {
	s := New(Options{})
	if !s.Ready() {
		t.Fatal("Ready() = false on a new server, want true")
	}
	if rec := do(t, s.Handler(), http.MethodGet, "/readyz"); rec.Code != http.StatusOK {
		t.Fatalf("GET /readyz = %d, want 200", rec.Code)
	}

	s.MarkShuttingDown()

	if s.Ready() {
		t.Fatal("Ready() = true after MarkShuttingDown, want false")
	}
	if rec := do(t, s.Handler(), http.MethodGet, "/readyz"); rec.Code != http.StatusServiceUnavailable {
		t.Fatalf("GET /readyz after MarkShuttingDown = %d, want 503", rec.Code)
	}
}

func TestNotFound(t *testing.T) {
	s := New(Options{})
	for _, p := range []string{"/nope", "/healthz/extra", "/a/b/c"} {
		if rec := do(t, s.Handler(), http.MethodGet, p); rec.Code != http.StatusNotFound {
			t.Errorf("GET %s = %d, want 404", p, rec.Code)
		}
	}
	if rec := do(t, s.Handler(), http.MethodPost, "/healthz"); rec.Code != http.StatusMethodNotAllowed {
		t.Errorf("POST /healthz = %d, want 405", rec.Code)
	}
}

func scrape(t *testing.T, h http.Handler) string {
	t.Helper()
	rec := do(t, h, http.MethodGet, "/metrics")
	if rec.Code != http.StatusOK {
		t.Fatalf("GET /metrics = %d, want 200", rec.Code)
	}
	return rec.Body.String()
}

func TestMetrics(t *testing.T) {
	s := New(Options{Version: testVersion})
	h := s.Handler()

	do(t, h, http.MethodGet, "/")
	do(t, h, http.MethodHead, "/")
	do(t, h, http.MethodGet, "/?name=Alice")
	do(t, h, http.MethodGet, "/healthz")
	for _, p := range []string{"/x", "/y", "/z/1", "/z/2"} {
		do(t, h, http.MethodGet, p)
	}
	do(t, h, "PURGE", "/")

	body := scrape(t, h)
	for _, want := range []string{
		`http_requests_total{code="200",handler="/",method="GET"} 2`,
		`http_requests_total{code="200",handler="/",method="HEAD"} 1`,
		`http_requests_total{code="200",handler="/healthz",method="GET"} 1`,
		`http_requests_total{code="404",handler="unmatched",method="GET"} 4`,
		`http_requests_total{code="405",handler="unmatched",method="OTHER"} 1`,
		`http_request_duration_seconds_count{handler="/",method="GET"} 2`,
		`http_request_duration_seconds_bucket{handler="unmatched",method="GET",le="+Inf"} 4`,
		`hello_api_build_info{goversion="` + runtime.Version() + `",version="` + testVersion + `"} 1`,
		"go_goroutines ",
	} {
		if !strings.Contains(body, want) {
			t.Errorf("metrics output does not contain %q", want)
		}
	}

	// The platform queries select on handler; raw paths must never become
	// label values.
	for _, unwanted := range []string{`route="`, `handler="/x"`, `handler="/z/1"`, `handler="/{$}"`, `method="PURGE"`} {
		if strings.Contains(body, unwanted) {
			t.Errorf("metrics output contains unbounded label %s", unwanted)
		}
	}
}

func TestRouteLabel(t *testing.T) {
	tests := map[string]string{
		"":                    UnmatchedRoute,
		"GET /{$}":            "/",
		"GET /healthz":        "/healthz",
		"/metrics":            "/metrics",
		"GET /items/{id}":     "/items/{id}",
		"example.com/static/": "/static/",
	}
	for in, want := range tests {
		if got := routeLabel(in); got != want {
			t.Errorf("routeLabel(%q) = %q, want %q", in, got, want)
		}
	}
}

func TestMethodLabel(t *testing.T) {
	for _, m := range []string{"GET", "HEAD", "POST", "PUT", "PATCH", "DELETE", "OPTIONS", "CONNECT", "TRACE"} {
		if got := methodLabel(m); got != m {
			t.Errorf("methodLabel(%q) = %q, want %q", m, got, m)
		}
	}
	for _, m := range []string{"get", "PURGE", "PROPFIND", ""} {
		if got := methodLabel(m); got != otherMethod {
			t.Errorf("methodLabel(%q) = %q, want %q", m, got, otherMethod)
		}
	}
}

func logLines(t *testing.T, out string) []map[string]any {
	t.Helper()
	var lines []map[string]any
	sc := bufio.NewScanner(strings.NewReader(out))
	for sc.Scan() {
		var m map[string]any
		if err := json.Unmarshal(sc.Bytes(), &m); err != nil {
			t.Fatalf("log line is not JSON: %q: %v", sc.Text(), err)
		}
		lines = append(lines, m)
	}
	return lines
}

func TestAccessLog(t *testing.T) {
	tests := []struct {
		name      string
		level     slog.Level
		target    string
		wantLines int
		wantLevel string
		wantRoute string
		wantCode  float64
	}{
		{"hello at info", slog.LevelInfo, "/?name=Alice", 1, "INFO", "/", 200},
		{"not found at info", slog.LevelInfo, "/missing", 1, "INFO", UnmatchedRoute, 404},
		{"healthz hidden at info", slog.LevelInfo, "/healthz", 0, "", "", 0},
		{"readyz hidden at info", slog.LevelInfo, "/readyz", 0, "", "", 0},
		{"metrics hidden at info", slog.LevelInfo, "/metrics", 0, "", "", 0},
		{"healthz at debug", slog.LevelDebug, "/healthz", 1, "DEBUG", "/healthz", 200},
	}
	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			var buf syncBuffer
			logger := slog.New(telemetry.NewLogHandler(slog.NewJSONHandler(&buf, &slog.HandlerOptions{Level: tt.level})))
			s := New(Options{Logger: logger})
			rec := do(t, s.Handler(), http.MethodGet, tt.target)

			lines := logLines(t, buf.String())
			if len(lines) != tt.wantLines {
				t.Fatalf("got %d log lines, want %d: %s", len(lines), tt.wantLines, buf.String())
			}
			if tt.wantLines == 0 {
				return
			}
			l := lines[0]
			if l["level"] != tt.wantLevel || l["msg"] != "request" {
				t.Errorf("level, msg = %v, %v, want %s, request", l["level"], l["msg"], tt.wantLevel)
			}
			if l["method"] != "GET" || l["route"] != tt.wantRoute || l["status"] != tt.wantCode {
				t.Errorf("method, route, status = %v, %v, %v, want GET, %s, %v", l["method"], l["route"], l["status"], tt.wantRoute, tt.wantCode)
			}
			wantPath, _, _ := strings.Cut(tt.target, "?")
			if l["path"] != wantPath {
				t.Errorf("path = %v, want %s", l["path"], wantPath)
			}
			if l["bytes"] != float64(rec.Body.Len()) {
				t.Errorf("bytes = %v, want %d", l["bytes"], rec.Body.Len())
			}
			if _, ok := l["duration_ms"].(float64); !ok {
				t.Errorf("duration_ms = %v, want a number", l["duration_ms"])
			}
			if _, ok := l["trace_id"]; ok {
				t.Errorf("trace_id present without an active span: %v", l)
			}
		})
	}
}

func TestTracing(t *testing.T) {
	sr := tracetest.NewSpanRecorder()
	tp := sdktrace.NewTracerProvider(sdktrace.WithSpanProcessor(sr))
	t.Cleanup(func() { _ = tp.Shutdown(t.Context()) })

	var buf syncBuffer
	s := New(Options{Logger: tracedLogger(&buf), TracerProvider: tp})

	req := httptest.NewRequestWithContext(t.Context(), http.MethodGet, "/", http.NoBody)
	req.Header.Set("traceparent", "00-"+parentTraceID+"-"+parentSpanID+"-01")
	s.Handler().ServeHTTP(httptest.NewRecorder(), req)
	do(t, s.Handler(), http.MethodGet, "/healthz")
	do(t, s.Handler(), http.MethodGet, "/metrics")

	spans := sr.Ended()
	if len(spans) != 1 {
		t.Fatalf("got %d spans, want 1 (probe and scrape paths are not traced)", len(spans))
	}
	span := spans[0]
	if span.Name() != "GET /" {
		t.Errorf("span name = %q, want %q", span.Name(), "GET /")
	}
	if got := span.SpanContext().TraceID().String(); got != parentTraceID {
		t.Errorf("trace id = %s, want the incoming %s", got, parentTraceID)
	}
	if got := span.Parent().SpanID().String(); got != parentSpanID {
		t.Errorf("parent span id = %s, want %s", got, parentSpanID)
	}
	var route string
	for _, kv := range span.Attributes() {
		if kv.Key == "http.route" {
			route = kv.Value.AsString()
		}
	}
	if route != "/" {
		t.Errorf("http.route = %q, want %q", route, "/")
	}

	lines := logLines(t, buf.String())
	if len(lines) != 3 {
		t.Fatalf("got %d log lines, want 3", len(lines))
	}
	// The log handler adds the trace attributes; the access log must not
	// add them a second time.
	first, _, _ := strings.Cut(buf.String(), "\n")
	for _, key := range []string{`"trace_id"`, `"span_id"`} {
		if n := strings.Count(first, key); n != 1 {
			t.Errorf("%s appears %d times in the access log line, want 1: %s", key, n, first)
		}
	}
	if lines[0]["trace_id"] != parentTraceID || lines[0]["span_id"] != span.SpanContext().SpanID().String() {
		t.Errorf("log trace_id, span_id = %v, %v, want %s, %s",
			lines[0]["trace_id"], lines[0]["span_id"], parentTraceID, span.SpanContext().SpanID())
	}
	for _, l := range lines[1:] {
		if _, ok := l["trace_id"]; ok {
			t.Errorf("untraced %v request logged a trace_id", l["route"])
		}
	}
}

// TestTraceparentWithTracingDisabled checks that with the default no-op
// tracer provider an incoming traceparent header still puts the caller's
// trace id in the access log.
func TestTraceparentWithTracingDisabled(t *testing.T) {
	var buf syncBuffer
	s := New(Options{Logger: tracedLogger(&buf)})

	req := httptest.NewRequestWithContext(t.Context(), http.MethodGet, "/", http.NoBody)
	req.Header.Set("traceparent", "00-"+parentTraceID+"-"+parentSpanID+"-01")
	s.Handler().ServeHTTP(httptest.NewRecorder(), req)

	lines := logLines(t, buf.String())
	if len(lines) != 1 {
		t.Fatalf("got %d log lines, want 1", len(lines))
	}
	if lines[0]["trace_id"] != parentTraceID || lines[0]["span_id"] != parentSpanID {
		t.Errorf("log trace_id, span_id = %v, %v, want the caller's %s, %s",
			lines[0]["trace_id"], lines[0]["span_id"], parentTraceID, parentSpanID)
	}
}

// scrapeOpenMetrics fetches /metrics in the OpenMetrics format, the only
// format that carries exemplars.
func scrapeOpenMetrics(t *testing.T, h http.Handler) string {
	t.Helper()
	req := httptest.NewRequestWithContext(t.Context(), http.MethodGet, PathMetrics, http.NoBody)
	req.Header.Set("Accept", "application/openmetrics-text; version=1.0.0")
	rec := httptest.NewRecorder()
	h.ServeHTTP(rec, req)
	if rec.Code != http.StatusOK {
		t.Fatalf("GET /metrics = %d, want 200", rec.Code)
	}
	if ct := rec.Header().Get("Content-Type"); !strings.HasPrefix(ct, "application/openmetrics-text") {
		t.Fatalf("Content-Type = %q, want application/openmetrics-text", ct)
	}
	return rec.Body.String()
}

// sampleLines returns the exposition lines of the named series (for a
// histogram, the series name including the _bucket suffix) whose labels
// include handler.
func sampleLines(body, series, handler string) []string {
	var out []string
	for line := range strings.Lines(body) {
		if strings.HasPrefix(line, series+"{") && strings.Contains(line, `handler="`+handler+`"`) {
			out = append(out, strings.TrimSpace(line))
		}
	}
	return out
}

func TestExemplars(t *testing.T) {
	tests := []struct {
		name string
		// sampler configures an SDK tracer provider; nil keeps the default
		// no-op provider, as when tracing is disabled.
		sampler      sdktrace.Sampler
		traceparent  string
		wantExemplar bool
	}{
		{name: "sampled span", sampler: sdktrace.AlwaysSample(), wantExemplar: true},
		{name: "unsampled span", sampler: sdktrace.NeverSample()},
		{name: "tracing disabled, no traceparent"},
		{name: "tracing disabled, sampled traceparent", traceparent: "00-" + parentTraceID + "-" + parentSpanID + "-01", wantExemplar: true},
		{name: "tracing disabled, unsampled traceparent", traceparent: "00-" + parentTraceID + "-" + parentSpanID + "-00"},
	}
	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			opts := Options{}
			var sr *tracetest.SpanRecorder
			if tt.sampler != nil {
				sr = tracetest.NewSpanRecorder()
				tp := sdktrace.NewTracerProvider(sdktrace.WithSampler(tt.sampler), sdktrace.WithSpanProcessor(sr))
				t.Cleanup(func() { _ = tp.Shutdown(context.Background()) })
				opts.TracerProvider = tp
			}
			s := New(opts)
			h := s.Handler()

			req := httptest.NewRequestWithContext(t.Context(), http.MethodGet, "/", http.NoBody)
			if tt.traceparent != "" {
				req.Header.Set("traceparent", tt.traceparent)
			}
			h.ServeHTTP(httptest.NewRecorder(), req)
			do(t, h, http.MethodGet, PathHealthz)

			wantTraceID := parentTraceID
			if sr != nil {
				if spans := sr.Ended(); len(spans) == 1 {
					wantTraceID = spans[0].SpanContext().TraceID().String()
				} else if tt.wantExemplar {
					t.Fatalf("got %d recorded spans, want 1", len(spans))
				}
			}
			exemplar := `# {trace_id="` + wantTraceID + `"}`

			body := scrapeOpenMetrics(t, h)
			counter := sampleLines(body, "http_requests_total", "/")
			buckets := sampleLines(body, "http_request_duration_seconds_bucket", "/")
			if len(counter) != 1 || len(buckets) == 0 {
				t.Fatalf("handler=\"/\" series missing; metrics:\n%s", body)
			}
			if got := strings.Contains(counter[0], exemplar); got != tt.wantExemplar {
				t.Errorf("counter exemplar %s present = %v, want %v: %s", exemplar, got, tt.wantExemplar, counter[0])
			}
			withExemplar := 0
			for _, l := range buckets {
				if strings.Contains(l, exemplar) {
					withExemplar++
				}
			}
			if want := map[bool]int{true: 1, false: 0}[tt.wantExemplar]; withExemplar != want {
				t.Errorf("%d histogram buckets carry exemplar %s, want %d:\n%s",
					withExemplar, exemplar, want, strings.Join(buckets, "\n"))
			}
			if !tt.wantExemplar && strings.Contains(strings.Join(append(counter, buckets...), "\n"), "# {") {
				t.Errorf("unexpected exemplar:\n%s", strings.Join(append(counter, buckets...), "\n"))
			}

			// Probes are not traced, so they never carry an exemplar.
			for _, l := range append(sampleLines(body, "http_requests_total", PathHealthz),
				sampleLines(body, "http_request_duration_seconds_bucket", PathHealthz)...) {
				if strings.Contains(l, "# {") {
					t.Errorf("probe sample has an exemplar: %s", l)
				}
			}

			// Scrapers that do not ask for OpenMetrics get the classic text
			// format, which has no exemplars.
			classic := scrape(t, h)
			if !strings.Contains(classic, `http_requests_total{code="200",handler="/",method="GET"} 1`+"\n") {
				t.Errorf("classic format lacks the request counter; metrics:\n%s", classic)
			}
			if strings.Contains(classic, "# {") {
				t.Error("classic text format contains exemplars")
			}
		})
	}
}

func TestStatusRecorderIgnoresInformational(t *testing.T) {
	rec := &statusRecorder{ResponseWriter: httptest.NewRecorder(), status: http.StatusOK}
	rec.WriteHeader(http.StatusEarlyHints)
	rec.WriteHeader(http.StatusAccepted)
	n, _ := io.WriteString(rec, "abc")
	if rec.status != http.StatusAccepted || rec.bytes != int64(n) {
		t.Errorf("status, bytes = %d, %d, want 202, %d", rec.status, rec.bytes, n)
	}
	if rec.Unwrap() == nil {
		t.Error("Unwrap() = nil")
	}
}
