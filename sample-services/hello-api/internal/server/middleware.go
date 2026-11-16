package server

import (
	"log/slog"
	"net/http"
	"time"

	semconv "go.opentelemetry.io/otel/semconv/v1.43.0"
	"go.opentelemetry.io/otel/trace"
)

// instrument records the request metrics and writes one access log line per
// request. Probe and scrape routes are logged at debug level.
//
// It runs inside the otelhttp handler, so the request context carries the
// server span (or, with tracing disabled, the span context of an incoming
// traceparent header). The metrics use it for exemplars. The access log does
// not add trace attributes itself: it logs with the request context, and the
// log handler (telemetry.NewLogHandler) adds trace_id and span_id.
func (s *Server) instrument(next http.Handler) http.Handler {
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		start := time.Now()
		rec := &statusRecorder{ResponseWriter: w, status: http.StatusOK}

		// The mux sets r.Pattern on this request value during routing.
		next.ServeHTTP(rec, r)

		elapsed := time.Since(start)
		ctx := r.Context()
		route := routeLabel(r.Pattern)
		// otelhttp names the server span after the matched pattern but does
		// not set the semantic-convention attribute http.route, which trace
		// search and span metrics group by. Unmatched requests get none, as
		// the convention requires a route template.
		if r.Pattern != "" {
			trace.SpanFromContext(ctx).SetAttributes(semconv.HTTPRoute(route))
		}
		s.metrics.observe(methodLabel(r.Method), route, rec.status, elapsed.Seconds(),
			trace.SpanContextFromContext(ctx))

		level := slog.LevelInfo
		if isQuietPath(route) {
			level = slog.LevelDebug
		}
		if !s.logger.Enabled(ctx, level) {
			return
		}
		s.logger.LogAttrs(ctx, level, "request",
			slog.String("method", r.Method),
			slog.String("route", route),
			slog.String("path", r.URL.Path),
			slog.Int("status", rec.status),
			slog.Float64("duration_ms", float64(elapsed.Microseconds())/1000),
			slog.Int64("bytes", rec.bytes),
		)
	})
}

// statusRecorder captures the final status code and the number of body bytes
// written.
type statusRecorder struct {
	http.ResponseWriter
	status      int
	bytes       int64
	wroteHeader bool
}

func (r *statusRecorder) WriteHeader(code int) {
	// Informational 1xx responses may precede the final status.
	if !r.wroteHeader && code >= http.StatusOK {
		r.status = code
		r.wroteHeader = true
	}
	r.ResponseWriter.WriteHeader(code)
}

func (r *statusRecorder) Write(b []byte) (int, error) {
	r.wroteHeader = true
	n, err := r.ResponseWriter.Write(b)
	r.bytes += int64(n)
	return n, err
}

// Unwrap lets http.ResponseController reach the underlying writer.
func (r *statusRecorder) Unwrap() http.ResponseWriter {
	return r.ResponseWriter
}
