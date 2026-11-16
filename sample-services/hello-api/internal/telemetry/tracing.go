// Package telemetry configures OpenTelemetry tracing from the standard OTEL_*
// environment variables and correlates log records with traces. Only traces
// are exported; metrics are served by the Prometheus endpoint and logs go to
// stdout.
package telemetry

import (
	"context"
	"fmt"
	"log/slog"
	"os"
	"strings"

	"go.opentelemetry.io/otel"
	"go.opentelemetry.io/otel/exporters/otlp/otlptrace/otlptracehttp"
	"go.opentelemetry.io/otel/propagation"
	"go.opentelemetry.io/otel/sdk/resource"
	sdktrace "go.opentelemetry.io/otel/sdk/trace"
	semconv "go.opentelemetry.io/otel/semconv/v1.43.0"
	"go.opentelemetry.io/otel/trace"
	tracenoop "go.opentelemetry.io/otel/trace/noop"
)

// DefaultServiceName is the service.name resource attribute used when
// OTEL_SERVICE_NAME and OTEL_RESOURCE_ATTRIBUTES do not set one.
const DefaultServiceName = "hello-api"

// Tracing holds the tracer provider and propagator used by the HTTP server.
type Tracing struct {
	// TracerProvider creates spans. It is a no-op provider when tracing is
	// disabled.
	TracerProvider trace.TracerProvider
	// Propagator extracts W3C trace context and baggage from incoming
	// requests. It is the same whether or not tracing is enabled.
	Propagator propagation.TextMapPropagator
	// Enabled reports whether spans are exported.
	Enabled bool

	shutdown func(context.Context) error
}

// Setup builds the tracing pipeline. Tracing is enabled when
// OTEL_EXPORTER_OTLP_ENDPOINT or OTEL_EXPORTER_OTLP_TRACES_ENDPOINT is set and
// OTEL_SDK_DISABLED is not "true". When enabled, spans are sent through an
// OTLP/HTTP exporter behind a batch span processor; the exporter, sampler and
// batch processor read their remaining settings from the standard OTEL_*
// variables. When disabled, no exporter is created and no network connection
// is made.
//
// When tracing is enabled, Setup also routes OpenTelemetry internal errors
// (for example failed exports) to logger, which replaces the process-wide
// OpenTelemetry error handler.
func Setup(ctx context.Context, version string, logger *slog.Logger) (*Tracing, error) {
	t := &Tracing{
		TracerProvider: tracenoop.NewTracerProvider(),
		Propagator:     NewPropagator(),
		shutdown:       func(context.Context) error { return nil },
	}
	if !exportEnabled() {
		return t, nil
	}

	for _, key := range []string{"OTEL_EXPORTER_OTLP_TRACES_PROTOCOL", "OTEL_EXPORTER_OTLP_PROTOCOL"} {
		if p := strings.TrimSpace(os.Getenv(key)); p != "" && p != "http/protobuf" {
			logger.Warn("unsupported OTLP protocol, using http/protobuf", "variable", key, "value", p)
		}
	}

	// Later options take precedence: OTEL_SERVICE_NAME and
	// OTEL_RESOURCE_ATTRIBUTES override the defaults set here.
	res, err := resource.New(ctx,
		resource.WithTelemetrySDK(),
		resource.WithAttributes(
			semconv.ServiceName(DefaultServiceName),
			semconv.ServiceVersion(version),
		),
		resource.WithFromEnv(),
	)
	if err != nil {
		return nil, fmt.Errorf("build OpenTelemetry resource: %w", err)
	}

	exporter, err := otlptracehttp.New(ctx)
	if err != nil {
		return nil, fmt.Errorf("create OTLP/HTTP trace exporter: %w", err)
	}

	tp := sdktrace.NewTracerProvider(
		sdktrace.WithBatcher(exporter),
		sdktrace.WithResource(res),
	)
	otel.SetErrorHandler(otel.ErrorHandlerFunc(func(err error) {
		logger.Warn("opentelemetry error", "error", err)
	}))

	t.TracerProvider = tp
	t.Enabled = true
	t.shutdown = tp.Shutdown
	return t, nil
}

// NewPropagator returns the W3C propagators for the traceparent and
// tracestate headers (Trace Context) and the baggage header (Baggage).
func NewPropagator() propagation.TextMapPropagator {
	return propagation.NewCompositeTextMapPropagator(propagation.TraceContext{}, propagation.Baggage{})
}

// Shutdown flushes buffered spans and releases the exporter. It is a no-op
// when tracing is disabled.
func (t *Tracing) Shutdown(ctx context.Context) error {
	return t.shutdown(ctx)
}

func exportEnabled() bool {
	if strings.EqualFold(strings.TrimSpace(os.Getenv("OTEL_SDK_DISABLED")), "true") {
		return false
	}
	return strings.TrimSpace(os.Getenv("OTEL_EXPORTER_OTLP_ENDPOINT")) != "" ||
		strings.TrimSpace(os.Getenv("OTEL_EXPORTER_OTLP_TRACES_ENDPOINT")) != ""
}
