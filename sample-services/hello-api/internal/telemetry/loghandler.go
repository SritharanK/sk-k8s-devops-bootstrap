package telemetry

import (
	"context"
	"log/slog"
	"slices"

	"go.opentelemetry.io/otel/trace"
)

// Log attribute keys for trace correlation. The Loki data source in Grafana
// derives a trace link from trace_id.
const (
	TraceIDKey = "trace_id"
	SpanIDKey  = "span_id"
)

// NewLogHandler returns a slog.Handler that adds the trace_id and span_id of
// the span in the record's context, as lowercase hex, to every record that
// next handles. Records whose context carries no valid span context pass
// through unchanged, so log calls without a context (slog.Info and friends)
// get no trace attributes. Use the context-aware logger methods (InfoContext,
// LogAttrs) for records that belong to a request.
//
// The two attributes are always written at the top level of the record, also
// when the logger was derived with WithGroup, so that log queries find them
// under the same key on every line.
//
// With tracing disabled the attributes still appear for requests that carry a
// W3C traceparent header: the propagator extracts the caller's span context
// and the no-op tracer returns it unchanged as the request span. trace_id is
// then the caller's trace id and span_id the caller's span id.
func NewLogHandler(next slog.Handler) slog.Handler {
	return &logHandler{next: next, root: next}
}

// logHandler keeps two views of the wrapped handler chain: next has every
// WithAttrs and WithGroup call applied, root only those made before the first
// WithGroup, and ops records the calls made since. A record with a span
// context is handled by root plus the trace attributes, with ops replayed on
// top, which keeps the trace attributes outside any group.
type logHandler struct {
	next slog.Handler
	root slog.Handler
	ops  []handlerOp
}

// handlerOp is a WithGroup call (group set) or a WithAttrs call.
type handlerOp struct {
	group string
	attrs []slog.Attr
}

func (h *logHandler) Enabled(ctx context.Context, level slog.Level) bool {
	return h.next.Enabled(ctx, level)
}

func (h *logHandler) Handle(ctx context.Context, r slog.Record) error {
	sc := trace.SpanContextFromContext(ctx)
	if !sc.IsValid() {
		return h.next.Handle(ctx, r)
	}
	ids := []slog.Attr{
		slog.String(TraceIDKey, sc.TraceID().String()),
		slog.String(SpanIDKey, sc.SpanID().String()),
	}
	if len(h.ops) == 0 {
		// The caller may still hold the record; Clone keeps AddAttrs from
		// writing into storage it shares with that copy.
		r = r.Clone()
		r.AddAttrs(ids...)
		return h.next.Handle(ctx, r)
	}
	handler := h.root.WithAttrs(ids)
	for _, op := range h.ops {
		if op.group != "" {
			handler = handler.WithGroup(op.group)
		} else {
			handler = handler.WithAttrs(op.attrs)
		}
	}
	return handler.Handle(ctx, r)
}

func (h *logHandler) WithAttrs(attrs []slog.Attr) slog.Handler {
	if len(attrs) == 0 {
		return h
	}
	c := &logHandler{next: h.next.WithAttrs(attrs), root: h.root, ops: h.ops}
	if len(h.ops) == 0 {
		c.root = c.next
	} else {
		c.ops = append(slices.Clip(h.ops), handlerOp{attrs: slices.Clone(attrs)})
	}
	return c
}

func (h *logHandler) WithGroup(name string) slog.Handler {
	if name == "" {
		return h
	}
	return &logHandler{
		next: h.next.WithGroup(name),
		root: h.root,
		ops:  append(slices.Clip(h.ops), handlerOp{group: name}),
	}
}
