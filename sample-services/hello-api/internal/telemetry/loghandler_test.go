package telemetry

import (
	"bufio"
	"bytes"
	"encoding/json"
	"log/slog"
	"net/http"
	"strconv"
	"strings"
	"testing"
	"testing/slogtest"
	"time"

	"go.opentelemetry.io/otel/propagation"
	"go.opentelemetry.io/otel/trace"
)

const (
	testTraceID = "4bf92f3577b34da6a3ce929d0e0e4736"
	testSpanID  = "00f067aa0ba902b7"
)

func spanContext(t *testing.T) trace.SpanContext {
	t.Helper()
	tid, err := trace.TraceIDFromHex(testTraceID)
	if err != nil {
		t.Fatal(err)
	}
	sid, err := trace.SpanIDFromHex(testSpanID)
	if err != nil {
		t.Fatal(err)
	}
	return trace.NewSpanContext(trace.SpanContextConfig{TraceID: tid, SpanID: sid, TraceFlags: trace.FlagsSampled})
}

// decodeLines parses JSON log output and also returns the raw lines, so that
// tests can detect duplicate keys that decoding into a map would hide.
func decodeLines(t *testing.T, out string) ([]map[string]any, []string) {
	t.Helper()
	var decoded []map[string]any
	var raw []string
	sc := bufio.NewScanner(strings.NewReader(out))
	for sc.Scan() {
		var m map[string]any
		if err := json.Unmarshal(sc.Bytes(), &m); err != nil {
			t.Fatalf("log line is not JSON: %q: %v", sc.Text(), err)
		}
		decoded = append(decoded, m)
		raw = append(raw, sc.Text())
	}
	return decoded, raw
}

func TestLogHandler(t *testing.T) {
	tests := []struct {
		name    string
		derive  func(*slog.Logger) *slog.Logger
		inGroup []string // path of nested groups that holds the record attributes
		want    map[string]any
	}{
		{
			name:   "plain logger",
			derive: func(l *slog.Logger) *slog.Logger { return l },
			want:   map[string]any{"k": "v"},
		},
		{
			name:   "WithAttrs",
			derive: func(l *slog.Logger) *slog.Logger { return l.With("component", "test") },
			want:   map[string]any{"component": "test", "k": "v"},
		},
		{
			name:    "WithGroup",
			derive:  func(l *slog.Logger) *slog.Logger { return l.WithGroup("req") },
			inGroup: []string{"req"},
			want:    map[string]any{"k": "v"},
		},
		{
			name:   "empty group name is ignored",
			derive: func(l *slog.Logger) *slog.Logger { return l.WithGroup("") },
			want:   map[string]any{"k": "v"},
		},
		{
			name: "attrs, nested groups and attrs",
			derive: func(l *slog.Logger) *slog.Logger {
				return l.With("component", "test").WithGroup("req").With("a", 1).WithGroup("inner").With("b", 2)
			},
			inGroup: []string{"req", "inner"},
			want:    map[string]any{"b": float64(2), "k": "v"},
		},
	}
	for _, tt := range tests {
		for _, withSpan := range []bool{true, false} {
			name := tt.name + "/without span"
			if withSpan {
				name = tt.name + "/with span"
			}
			t.Run(name, func(t *testing.T) {
				var buf bytes.Buffer
				logger := tt.derive(slog.New(NewLogHandler(slog.NewJSONHandler(&buf, nil))))
				ctx := t.Context()
				if withSpan {
					ctx = trace.ContextWithSpanContext(ctx, spanContext(t))
				}
				logger.InfoContext(ctx, "msg", "k", "v")

				lines, raw := decodeLines(t, buf.String())
				if len(lines) != 1 {
					t.Fatalf("got %d lines, want 1: %s", len(lines), buf.String())
				}
				line := lines[0]
				wantTrace := map[string]any{TraceIDKey: testTraceID, SpanIDKey: testSpanID}
				for key, want := range wantTrace {
					got, ok := line[key]
					if withSpan && got != want {
						t.Errorf("top-level %s = %v, want %s; line: %s", key, got, want, raw[0])
					}
					if !withSpan && ok {
						t.Errorf("%s = %v present without a span context", key, got)
					}
					wantCount := 0
					if withSpan {
						wantCount = 1
					}
					if n := strings.Count(raw[0], `"`+key+`"`); n != wantCount {
						t.Errorf("%s appears %d times, want %d; line: %s", key, n, wantCount, raw[0])
					}
				}

				attrs := line
				for _, g := range tt.inGroup {
					next, ok := attrs[g].(map[string]any)
					if !ok {
						t.Fatalf("group %q missing; line: %s", g, raw[0])
					}
					attrs = next
				}
				for k, want := range tt.want {
					if got := attrs[k]; got != want {
						t.Errorf("%s = %v, want %v; line: %s", k, got, want, raw[0])
					}
				}
			})
		}
	}
}

func TestLogHandlerEnabledDelegates(t *testing.T) {
	h := NewLogHandler(slog.NewJSONHandler(&bytes.Buffer{}, &slog.HandlerOptions{Level: slog.LevelWarn}))
	for _, h := range []slog.Handler{h, h.WithAttrs([]slog.Attr{slog.Int("a", 1)}), h.WithGroup("g")} {
		if h.Enabled(t.Context(), slog.LevelInfo) {
			t.Errorf("%T.Enabled(info) = true, want false below the wrapped handler's level", h)
		}
		if !h.Enabled(t.Context(), slog.LevelError) {
			t.Errorf("%T.Enabled(error) = false, want true", h)
		}
	}
}

// TestLogHandlerSharedRecord handles the same record twice. Without a Clone,
// the second AddAttrs would find the first call's attributes in the shared
// backing array and slog would add a "!BUG" attribute.
func TestLogHandlerSharedRecord(t *testing.T) {
	var buf bytes.Buffer
	h := NewLogHandler(slog.NewJSONHandler(&buf, nil))
	ctx := trace.ContextWithSpanContext(t.Context(), spanContext(t))
	r := slog.NewRecord(time.Time{}, slog.LevelInfo, "msg", 0)
	// Five attributes are stored inline; adding the other five one at a time
	// leaves the backing array with room for the two trace attributes.
	for i := range 10 {
		r.AddAttrs(slog.Int("n"+strconv.Itoa(i), i))
	}
	for range 2 {
		if err := h.Handle(ctx, r); err != nil {
			t.Fatalf("Handle() error = %v", err)
		}
	}
	if got := r.NumAttrs(); got != 10 {
		t.Errorf("caller record has %d attributes after Handle, want 10", got)
	}
	lines, raw := decodeLines(t, buf.String())
	if len(lines) != 2 {
		t.Fatalf("got %d lines, want 2", len(lines))
	}
	for i, l := range lines {
		if strings.Contains(raw[i], "!BUG") || l[TraceIDKey] != testTraceID {
			t.Errorf("line %d = %s, want trace_id %s and no !BUG attribute", i, raw[i], testTraceID)
		}
	}
}

// TestLogHandlerConformance runs the standard library handler test suite
// against the wrapper. Its records have no span context, so the wrapper must
// behave exactly like the JSON handler it wraps.
func TestLogHandlerConformance(t *testing.T) {
	var buf bytes.Buffer
	newHandler := func(*testing.T) slog.Handler {
		buf.Reset()
		return NewLogHandler(slog.NewJSONHandler(&buf, nil))
	}
	result := func(t *testing.T) map[string]any {
		t.Helper()
		var m map[string]any
		if err := json.Unmarshal(buf.Bytes(), &m); err != nil {
			t.Fatalf("decode %q: %v", buf.String(), err)
		}
		return m
	}
	slogtest.Run(t, newHandler, result)
}

// TestLogHandlerTraceparentWithTracingDisabled checks the claim in the
// NewLogHandler documentation: with tracing disabled, the no-op tracer keeps
// the span context extracted from an incoming traceparent header, so log
// records carry the caller's trace id and span id.
func TestLogHandlerTraceparentWithTracingDisabled(t *testing.T) {
	clearOTelEnv(t)
	tr, err := Setup(t.Context(), "1.2.3", discard)
	if err != nil {
		t.Fatalf("Setup() error = %v", err)
	}
	if tr.Enabled {
		t.Fatal("Enabled = true, want tracing disabled")
	}

	header := http.Header{}
	header.Set("traceparent", "00-"+testTraceID+"-"+testSpanID+"-01")
	ctx := tr.Propagator.Extract(t.Context(), propagation.HeaderCarrier(header))
	ctx, span := tr.TracerProvider.Tracer("test").Start(ctx, "op")
	defer span.End()

	var buf bytes.Buffer
	slog.New(NewLogHandler(slog.NewJSONHandler(&buf, nil))).InfoContext(ctx, "request")
	lines, _ := decodeLines(t, buf.String())
	if len(lines) != 1 {
		t.Fatalf("got %d lines, want 1", len(lines))
	}
	if lines[0][TraceIDKey] != testTraceID || lines[0][SpanIDKey] != testSpanID {
		t.Errorf("trace_id, span_id = %v, %v, want %s, %s",
			lines[0][TraceIDKey], lines[0][SpanIDKey], testTraceID, testSpanID)
	}
}
