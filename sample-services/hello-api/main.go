// Command hello-api is a small HTTP service used to exercise the platform
// contract: health and readiness probes, Prometheus metrics, structured logs,
// optional OpenTelemetry tracing and graceful shutdown.
package main

import (
	"context"
	"flag"
	"fmt"
	"io"
	"log/slog"
	"net"
	"os"
	"os/signal"
	"runtime"
	"syscall"
	"time"

	"github.com/SritharanK/sk-k8s-devops-bootstrap/sample-services/hello-api/internal/config"
	"github.com/SritharanK/sk-k8s-devops-bootstrap/sample-services/hello-api/internal/server"
	"github.com/SritharanK/sk-k8s-devops-bootstrap/sample-services/hello-api/internal/telemetry"
)

// version is set at build time with -ldflags "-X main.version=<v>".
var version = "dev"

// traceFlushTimeout bounds the final export of buffered spans on exit.
const traceFlushTimeout = 2 * time.Second

func main() {
	healthcheck := flag.Bool("healthcheck", false,
		"probe GET /healthz on 127.0.0.1 at the HTTP_ADDR port, then exit 0 when healthy or 1 otherwise")
	flag.Parse()

	if *healthcheck {
		if err := runHealthcheck(context.Background(), os.Getenv); err != nil {
			fmt.Fprintln(os.Stderr, "healthcheck failed:", err)
			os.Exit(1)
		}
		return
	}

	ctx, stop := signal.NotifyContext(context.Background(), syscall.SIGTERM, os.Interrupt)
	// Restore default signal handling after the first signal, so a second
	// one terminates the process without waiting for the drain.
	context.AfterFunc(ctx, stop)

	err := run(ctx, os.Getenv, os.Stdout)
	stop()
	if err != nil {
		slog.New(slog.NewJSONHandler(os.Stdout, nil)).Error("hello-api stopped with an error", "error", err.Error())
		os.Exit(1)
	}
}

// run loads the configuration, starts the server and blocks until ctx is
// cancelled and the server has shut down.
func run(ctx context.Context, getenv func(string) string, stdout io.Writer) error {
	cfg, err := config.Load(getenv)
	if err != nil {
		return fmt.Errorf("invalid configuration: %w", err)
	}
	// Every record logged with a request context gets trace_id and span_id.
	logger := slog.New(telemetry.NewLogHandler(
		slog.NewJSONHandler(stdout, &slog.HandlerOptions{Level: cfg.LogLevel})))

	tracing, err := telemetry.Setup(ctx, version, logger)
	if err != nil {
		return err
	}
	defer func() {
		flushCtx, cancel := context.WithTimeout(context.WithoutCancel(ctx), traceFlushTimeout)
		defer cancel()
		if shutdownErr := tracing.Shutdown(flushCtx); shutdownErr != nil {
			logger.Warn("trace exporter shutdown failed", "error", shutdownErr.Error())
		}
	}()

	srv := server.New(server.Options{
		Version:        version,
		Logger:         logger,
		TracerProvider: tracing.TracerProvider,
		Propagator:     tracing.Propagator,
	})

	ln, err := (&net.ListenConfig{}).Listen(ctx, "tcp", cfg.HTTPAddr)
	if err != nil {
		return fmt.Errorf("listen on %s: %w", cfg.HTTPAddr, err)
	}

	logger.Info("starting hello-api",
		"version", version,
		"go_version", runtime.Version(),
		"addr", ln.Addr().String(),
		"log_level", cfg.LogLevel.String(),
		"tracing", tracing.Enabled,
		"shutdown_delay", cfg.ShutdownDelay.String(),
		"shutdown_timeout", cfg.ShutdownTimeout.String(),
	)

	return srv.Run(ctx, ln, server.DrainConfig{
		Delay:   cfg.ShutdownDelay,
		Timeout: cfg.ShutdownTimeout,
	})
}

// runHealthcheck probes the local /healthz endpoint on the configured port.
func runHealthcheck(ctx context.Context, getenv func(string) string) error {
	cfg, err := config.Load(getenv)
	if err != nil {
		return fmt.Errorf("invalid configuration: %w", err)
	}
	port, err := config.Port(cfg.HTTPAddr)
	if err != nil {
		return err
	}
	return server.Healthcheck(ctx, port)
}
