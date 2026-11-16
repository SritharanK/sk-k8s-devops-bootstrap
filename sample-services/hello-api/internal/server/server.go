// Package server implements the hello-api HTTP handlers, request
// instrumentation, readiness state and graceful shutdown.
package server

import (
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"log/slog"
	"net/http"
	"strings"
	"sync/atomic"
	"unicode"
	"unicode/utf8"

	"go.opentelemetry.io/contrib/instrumentation/net/http/otelhttp"
	metricnoop "go.opentelemetry.io/otel/metric/noop"
	"go.opentelemetry.io/otel/propagation"
	"go.opentelemetry.io/otel/trace"
	tracenoop "go.opentelemetry.io/otel/trace/noop"

	"github.com/SritharanK/sk-k8s-devops-bootstrap/sample-services/hello-api/internal/telemetry"
)

// ServiceName is the name reported in responses and used as the operation
// name for server spans.
const ServiceName = "hello-api"

// MaxNameLength is the maximum number of characters accepted in the name
// query parameter of GET /.
const MaxNameLength = 64

// Probe and scrape paths. Requests to these paths are logged at debug level
// and are not traced.
const (
	PathHealthz = "/healthz"
	PathReadyz  = "/readyz"
	PathMetrics = "/metrics"
)

// Options configures a Server.
type Options struct {
	// Version is reported by GET / and by the hello_api_build_info metric.
	Version string
	// Logger receives access logs and lifecycle events. Nil discards them.
	// Access log records carry the request context; wrap the handler with
	// telemetry.NewLogHandler to add trace_id and span_id to them.
	Logger *slog.Logger
	// TracerProvider creates server spans. Nil uses a no-op provider.
	TracerProvider trace.TracerProvider
	// Propagator extracts trace context from request headers. Nil uses
	// telemetry.NewPropagator: W3C Trace Context and Baggage.
	Propagator propagation.TextMapPropagator
}

// Server holds the HTTP handler and the readiness state of the service.
type Server struct {
	version      string
	logger       *slog.Logger
	metrics      *metrics
	handler      http.Handler
	shuttingDown atomic.Bool
}

// New builds a Server with its routes, metrics registry and middleware.
func New(opts Options) *Server {
	if opts.Logger == nil {
		opts.Logger = slog.New(slog.DiscardHandler)
	}
	if opts.TracerProvider == nil {
		opts.TracerProvider = tracenoop.NewTracerProvider()
	}
	if opts.Propagator == nil {
		opts.Propagator = telemetry.NewPropagator()
	}

	s := &Server{
		version: opts.Version,
		logger:  opts.Logger,
		metrics: newMetrics(opts.Version),
	}

	mux := http.NewServeMux()
	mux.HandleFunc("GET /{$}", s.handleHello)
	mux.HandleFunc("GET "+PathHealthz, s.handleHealthz)
	mux.HandleFunc("GET "+PathReadyz, s.handleReadyz)
	mux.Handle("GET "+PathMetrics, s.metrics.handler())

	// The instrumentation middleware must receive the request that is passed
	// to the mux, so that it can read the matched pattern after routing.
	s.handler = otelhttp.NewHandler(s.instrument(mux), ServiceName,
		otelhttp.WithTracerProvider(opts.TracerProvider),
		otelhttp.WithPropagators(opts.Propagator),
		otelhttp.WithMeterProvider(metricnoop.NewMeterProvider()),
		otelhttp.WithFilter(func(r *http.Request) bool { return !isQuietPath(r.URL.Path) }),
		otelhttp.WithSpanNameFormatter(spanName),
	)
	return s
}

// Handler returns the root HTTP handler with tracing, metrics and access
// logging applied.
func (s *Server) Handler() http.Handler {
	return s.handler
}

// MarkShuttingDown makes /readyz return 503 from now on. It is safe for
// concurrent use.
func (s *Server) MarkShuttingDown() {
	s.shuttingDown.Store(true)
}

// Ready reports whether /readyz currently returns 200.
func (s *Server) Ready() bool {
	return !s.shuttingDown.Load()
}

type helloResponse struct {
	Service string `json:"service"`
	Version string `json:"version"`
	Message string `json:"message"`
}

type errorResponse struct {
	Error string `json:"error"`
}

func (s *Server) handleHello(w http.ResponseWriter, r *http.Request) {
	message := "Hello from " + ServiceName
	if name := strings.TrimSpace(r.URL.Query().Get("name")); name != "" {
		if err := validateName(name); err != nil {
			writeJSON(w, http.StatusBadRequest, errorResponse{Error: err.Error()})
			return
		}
		message = "Hello " + name + " from " + ServiceName
	}
	writeJSON(w, http.StatusOK, helloResponse{
		Service: ServiceName,
		Version: s.version,
		Message: message,
	})
}

func (s *Server) handleHealthz(w http.ResponseWriter, _ *http.Request) {
	writeText(w, http.StatusOK, "ok\n")
}

func (s *Server) handleReadyz(w http.ResponseWriter, _ *http.Request) {
	if !s.Ready() {
		writeText(w, http.StatusServiceUnavailable, "shutting down\n")
		return
	}
	writeText(w, http.StatusOK, "ok\n")
}

func validateName(name string) error {
	if !utf8.ValidString(name) {
		return errors.New("name must be valid UTF-8")
	}
	if utf8.RuneCountInString(name) > MaxNameLength {
		return fmt.Errorf("name must be at most %d characters", MaxNameLength)
	}
	for _, r := range name {
		if unicode.IsControl(r) {
			return errors.New("name must not contain control characters")
		}
	}
	return nil
}

func writeJSON(w http.ResponseWriter, status int, v any) {
	body, err := json.Marshal(v)
	if err != nil {
		http.Error(w, "internal server error", http.StatusInternalServerError)
		return
	}
	h := w.Header()
	h.Set("Content-Type", "application/json")
	h.Set("X-Content-Type-Options", "nosniff")
	w.WriteHeader(status)
	_, _ = w.Write(append(body, '\n'))
}

func writeText(w http.ResponseWriter, status int, body string) {
	h := w.Header()
	h.Set("Content-Type", "text/plain; charset=utf-8")
	h.Set("X-Content-Type-Options", "nosniff")
	w.WriteHeader(status)
	_, _ = io.WriteString(w, body)
}

// spanName names server spans "METHOD route", using the same route value as
// the handler metric label and the route access log field. Before routing the pattern is empty and the
// span is named after the method only; otelhttp renames it after the mux has
// matched a pattern.
func spanName(_ string, r *http.Request) string {
	if r.Pattern == "" {
		return methodLabel(r.Method)
	}
	return methodLabel(r.Method) + " " + routeLabel(r.Pattern)
}

func isQuietPath(path string) bool {
	return path == PathHealthz || path == PathReadyz || path == PathMetrics
}
