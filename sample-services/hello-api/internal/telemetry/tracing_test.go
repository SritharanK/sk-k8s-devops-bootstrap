package telemetry

import (
	"bytes"
	"context"
	"log/slog"
	"net/http"
	"slices"
	"strings"
	"testing"
	"time"

	"go.opentelemetry.io/otel/attribute"
	"go.opentelemetry.io/otel/baggage"
	"go.opentelemetry.io/otel/propagation"
	sdktrace "go.opentelemetry.io/otel/sdk/trace"
	tracenoop "go.opentelemetry.io/otel/trace/noop"
)

var discard = slog.New(slog.DiscardHandler)

func clearOTelEnv(t *testing.T) {
	t.Helper()
	for _, k := range []string{
		"OTEL_SDK_DISABLED",
		"OTEL_EXPORTER_OTLP_ENDPOINT",
		"OTEL_EXPORTER_OTLP_TRACES_ENDPOINT",
		"OTEL_EXPORTER_OTLP_PROTOCOL",
		"OTEL_EXPORTER_OTLP_TRACES_PROTOCOL",
		"OTEL_SERVICE_NAME",
		"OTEL_RESOURCE_ATTRIBUTES",
	} {
		t.Setenv(k, "")
	}
}

// assertW3CPropagator checks that p handles the W3C Trace Context and Baggage
// headers, and that it extracts and injects both.
func assertW3CPropagator(t *testing.T, p propagation.TextMapPropagator) {
	t.Helper()
	// The composite propagator returns its fields in map order.
	fields := p.Fields()
	slices.Sort(fields)
	if got, want := strings.Join(fields, ","), "baggage,traceparent,tracestate"; got != want {
		t.Errorf("Propagator fields = %s, want %s", got, want)
	}
	in := propagation.HeaderCarrier(http.Header{})
	in.Set("traceparent", "00-4bf92f3577b34da6a3ce929d0e0e4736-00f067aa0ba902b7-01")
	in.Set("baggage", "tenant=example")
	ctx := p.Extract(context.Background(), in)
	if got := baggage.FromContext(ctx).Member("tenant").Value(); got != "example" {
		t.Errorf("extracted baggage tenant = %q, want example", got)
	}
	out := propagation.HeaderCarrier(http.Header{})
	p.Inject(ctx, out)
	for _, k := range []string{"traceparent", "baggage"} {
		if out.Get(k) != in.Get(k) {
			t.Errorf("injected %s = %q, want %q", k, out.Get(k), in.Get(k))
		}
	}
}

func TestSetupDisabledWithoutEndpoint(t *testing.T) {
	clearOTelEnv(t)

	tr, err := Setup(t.Context(), "1.2.3", discard)
	if err != nil {
		t.Fatalf("Setup() error = %v", err)
	}
	if tr.Enabled {
		t.Error("Enabled = true, want false")
	}
	if _, ok := tr.TracerProvider.(tracenoop.TracerProvider); !ok {
		t.Errorf("TracerProvider = %T, want noop.TracerProvider", tr.TracerProvider)
	}
	assertW3CPropagator(t, tr.Propagator)
	_, span := tr.TracerProvider.Tracer("test").Start(t.Context(), "op")
	if span.IsRecording() {
		t.Error("span is recording, want no-op span")
	}
	span.End()
	if err := tr.Shutdown(t.Context()); err != nil {
		t.Errorf("Shutdown() error = %v", err)
	}
}

func TestSetupDisabledBySDKFlag(t *testing.T) {
	clearOTelEnv(t)
	t.Setenv("OTEL_EXPORTER_OTLP_ENDPOINT", "http://127.0.0.1:4318")
	t.Setenv("OTEL_SDK_DISABLED", "true")

	tr, err := Setup(t.Context(), "1.2.3", discard)
	if err != nil {
		t.Fatalf("Setup() error = %v", err)
	}
	if tr.Enabled {
		t.Error("Enabled = true, want false when OTEL_SDK_DISABLED=true")
	}
}

func TestSetupEnabled(t *testing.T) {
	tests := []struct {
		name        string
		env         map[string]string
		wantService string
	}{
		{
			name:        "generic endpoint, default service name",
			env:         map[string]string{"OTEL_EXPORTER_OTLP_ENDPOINT": "http://127.0.0.1:4318"},
			wantService: DefaultServiceName,
		},
		{
			name: "traces endpoint, service name from env",
			env: map[string]string{
				"OTEL_EXPORTER_OTLP_TRACES_ENDPOINT": "http://127.0.0.1:4318/v1/traces",
				"OTEL_SERVICE_NAME":                  "hello-api-test",
			},
			wantService: "hello-api-test",
		},
	}
	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			clearOTelEnv(t)
			for k, v := range tt.env {
				t.Setenv(k, v)
			}

			tr, err := Setup(t.Context(), "1.2.3", discard)
			if err != nil {
				t.Fatalf("Setup() error = %v", err)
			}
			t.Cleanup(func() {
				// t.Context() is already cancelled when cleanups run.
				ctx, cancel := context.WithTimeout(context.Background(), 2*time.Second)
				defer cancel()
				if err := tr.Shutdown(ctx); err != nil {
					t.Errorf("Shutdown() error = %v", err)
				}
			})
			if !tr.Enabled {
				t.Fatal("Enabled = false, want true")
			}
			if _, ok := tr.TracerProvider.(*sdktrace.TracerProvider); !ok {
				t.Fatalf("TracerProvider = %T, want *trace.TracerProvider", tr.TracerProvider)
			}
			assertW3CPropagator(t, tr.Propagator)

			// The span is deliberately not ended, so nothing is exported and
			// the test makes no network calls.
			_, span := tr.TracerProvider.Tracer("test").Start(t.Context(), "op")
			if !span.IsRecording() || !span.SpanContext().IsValid() {
				t.Fatal("span is not recording, want a sampled span")
			}
			ro, ok := span.(sdktrace.ReadOnlySpan)
			if !ok {
				t.Fatalf("span = %T, want sdktrace.ReadOnlySpan", span)
			}
			attrs := map[attribute.Key]string{}
			for _, kv := range ro.Resource().Attributes() {
				attrs[kv.Key] = kv.Value.Emit()
			}
			if got := attrs["service.name"]; got != tt.wantService {
				t.Errorf("service.name = %q, want %q", got, tt.wantService)
			}
			if got := attrs["service.version"]; got != "1.2.3" {
				t.Errorf("service.version = %q, want %q", got, "1.2.3")
			}
		})
	}
}

func TestSetupWarnsOnUnsupportedProtocol(t *testing.T) {
	clearOTelEnv(t)
	t.Setenv("OTEL_EXPORTER_OTLP_ENDPOINT", "http://127.0.0.1:4318")
	t.Setenv("OTEL_EXPORTER_OTLP_PROTOCOL", "grpc")

	var buf bytes.Buffer
	tr, err := Setup(t.Context(), "1.2.3", slog.New(slog.NewJSONHandler(&buf, nil)))
	if err != nil {
		t.Fatalf("Setup() error = %v", err)
	}
	ctx, cancel := context.WithTimeout(context.Background(), 2*time.Second)
	defer cancel()
	if err := tr.Shutdown(ctx); err != nil {
		t.Errorf("Shutdown() error = %v", err)
	}
	if !strings.Contains(buf.String(), "unsupported OTLP protocol") {
		t.Errorf("log output = %q, want an unsupported protocol warning", buf.String())
	}
}
