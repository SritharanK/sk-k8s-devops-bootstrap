package server

import (
	"net/http"
	"runtime"
	"strconv"
	"strings"

	"github.com/prometheus/client_golang/prometheus"
	"github.com/prometheus/client_golang/prometheus/collectors"
	"github.com/prometheus/client_golang/prometheus/promhttp"
	"go.opentelemetry.io/otel/trace"
)

// UnmatchedRoute is the handler label value (and access log route) for
// requests that matched no registered pattern (404 and 405 responses). It
// keeps label cardinality bounded.
const UnmatchedRoute = "unmatched"

// exemplarTraceIDKey is the exemplar label that carries the trace id. Grafana
// links an exemplar to its trace through this label.
const exemplarTraceIDKey = "trace_id"

// otherMethod is the method label for request methods outside the standard
// set, so that arbitrary client input cannot create new series.
const otherMethod = "OTHER"

type metrics struct {
	registry *prometheus.Registry
	requests *prometheus.CounterVec
	duration *prometheus.HistogramVec
}

func newMetrics(version string) *metrics {
	m := &metrics{
		registry: prometheus.NewRegistry(),
		requests: prometheus.NewCounterVec(prometheus.CounterOpts{
			Name: "http_requests_total",
			Help: "HTTP requests handled, by method, handler (route pattern) and status code.",
		}, []string{"method", "handler", "code"}),
		duration: prometheus.NewHistogramVec(prometheus.HistogramOpts{
			Name:    "http_request_duration_seconds",
			Help:    "HTTP request duration in seconds, by method and handler (route pattern).",
			Buckets: prometheus.DefBuckets,
		}, []string{"method", "handler"}),
	}

	buildInfo := prometheus.NewGaugeVec(prometheus.GaugeOpts{
		Name: "hello_api_build_info",
		Help: "Build information of hello-api. The value is always 1.",
	}, []string{"version", "goversion"})
	buildInfo.WithLabelValues(version, runtime.Version()).Set(1)

	m.registry.MustRegister(
		collectors.NewGoCollector(),
		collectors.NewProcessCollector(collectors.ProcessCollectorOpts{}),
		m.requests,
		m.duration,
		buildInfo,
	)
	return m
}

// handler serves the registry. Exemplars exist only in the OpenMetrics format,
// so the handler offers it to scrapers that ask for it in the Accept header;
// scrapers that do not still get the classic Prometheus text format.
func (m *metrics) handler() http.Handler {
	return promhttp.HandlerFor(m.registry, promhttp.HandlerOpts{
		Registry:          m.registry,
		EnableOpenMetrics: true,
	})
}

// observe counts a finished request and records its duration. When sc belongs
// to a sampled trace, both samples carry an exemplar with its trace id. With
// tracing disabled, sc is the caller's span context from an incoming
// traceparent header, so the exemplar points to the caller's trace.
func (m *metrics) observe(method, handler string, code int, seconds float64, sc trace.SpanContext) {
	counter := m.requests.WithLabelValues(method, handler, strconv.Itoa(code))
	observer := m.duration.WithLabelValues(method, handler)
	if !sc.IsValid() || !sc.IsSampled() {
		counter.Inc()
		observer.Observe(seconds)
		return
	}
	exemplar := prometheus.Labels{exemplarTraceIDKey: sc.TraceID().String()}
	// client_golang counters and histograms implement both interfaces; the
	// fallbacks only guard against a future change of the concrete types.
	if ea, ok := counter.(prometheus.ExemplarAdder); ok {
		ea.AddWithExemplar(1, exemplar)
	} else {
		counter.Inc()
	}
	if eo, ok := observer.(prometheus.ExemplarObserver); ok {
		eo.ObserveWithExemplar(seconds, exemplar)
	} else {
		observer.Observe(seconds)
	}
}

// routeLabel converts a ServeMux pattern such as "GET /healthz" into the
// handler label "/healthz". The method is dropped because it has its own label,
// and the "{$}" end anchor is removed so that "GET /{$}" becomes "/".
func routeLabel(pattern string) string {
	if pattern == "" {
		return UnmatchedRoute
	}
	if i := strings.IndexByte(pattern, '/'); i >= 0 {
		pattern = pattern[i:]
	}
	return strings.TrimSuffix(pattern, "{$}")
}

func methodLabel(method string) string {
	switch method {
	case http.MethodGet, http.MethodHead, http.MethodPost, http.MethodPut,
		http.MethodPatch, http.MethodDelete, http.MethodOptions,
		http.MethodConnect, http.MethodTrace:
		return method
	default:
		return otherMethod
	}
}
