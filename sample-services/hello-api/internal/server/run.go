package server

import (
	"context"
	"errors"
	"fmt"
	"io"
	"log/slog"
	"net"
	"net/http"
	"strconv"
	"time"
)

// HTTP server timeouts. WriteTimeout leaves ample room for the slowest
// handler, /metrics.
const (
	ReadHeaderTimeout = 5 * time.Second
	ReadTimeout       = 10 * time.Second
	WriteTimeout      = 15 * time.Second
	IdleTimeout       = 60 * time.Second
)

// HealthcheckTimeout bounds the request made by Healthcheck.
const HealthcheckTimeout = 2 * time.Second

// DrainConfig controls the shutdown sequence of Run.
type DrainConfig struct {
	// Delay is the time between failing readiness and closing the listener.
	Delay time.Duration
	// Timeout bounds the wait for in-flight requests to complete.
	Timeout time.Duration
}

// NewHTTPServer returns an http.Server for h with header, read, write and idle
// timeouts set and internal errors routed to logger.
func NewHTTPServer(h http.Handler, logger *slog.Logger) *http.Server {
	return &http.Server{
		Handler:           h,
		ReadHeaderTimeout: ReadHeaderTimeout,
		ReadTimeout:       ReadTimeout,
		WriteTimeout:      WriteTimeout,
		IdleTimeout:       IdleTimeout,
		ErrorLog:          slog.NewLogLogger(logger.Handler(), slog.LevelWarn),
	}
}

// Run serves HTTP on ln until ctx is cancelled and then shuts down in three
// steps: /readyz starts returning 503, the listener keeps accepting traffic for
// d.Delay so that endpoint controllers and load balancers stop routing to the
// pod, and finally in-flight requests get up to d.Timeout to complete. Run
// returns nil after a clean shutdown. The listener is closed when Run returns.
func (s *Server) Run(ctx context.Context, ln net.Listener, d DrainConfig) error {
	return serve(ctx, NewHTTPServer(s.handler, s.logger), ln, d, s.logger, s.MarkShuttingDown)
}

func serve(ctx context.Context, srv *http.Server, ln net.Listener, d DrainConfig, logger *slog.Logger, beforeDrain func()) error {
	serveErr := make(chan error, 1)
	go func() { serveErr <- srv.Serve(ln) }()

	select {
	case err := <-serveErr:
		return fmt.Errorf("serve: %w", err)
	case <-ctx.Done():
	}

	beforeDrain()
	logger.Info("shutdown started, readiness failing",
		"delay", d.Delay.String(), "timeout", d.Timeout.String())
	time.Sleep(d.Delay)

	logger.Info("closing listener and draining connections")
	shutdownCtx, cancel := context.WithTimeout(context.WithoutCancel(ctx), d.Timeout)
	defer cancel()
	if err := srv.Shutdown(shutdownCtx); err != nil {
		closeErr := srv.Close()
		return errors.Join(fmt.Errorf("graceful shutdown: %w", err), closeErr)
	}
	if err := <-serveErr; !errors.Is(err, http.ErrServerClosed) {
		return fmt.Errorf("serve: %w", err)
	}
	logger.Info("shutdown complete")
	return nil
}

// Healthcheck sends GET /healthz to 127.0.0.1 on the given port and returns
// nil when the response status is 200. It is used by the container health
// check, because the runtime image has no shell or HTTP client.
func Healthcheck(ctx context.Context, port int) error {
	ctx, cancel := context.WithTimeout(ctx, HealthcheckTimeout)
	defer cancel()

	url := "http://" + net.JoinHostPort("127.0.0.1", strconv.Itoa(port)) + PathHealthz
	req, err := http.NewRequestWithContext(ctx, http.MethodGet, url, http.NoBody)
	if err != nil {
		return err
	}
	client := &http.Client{Transport: &http.Transport{Proxy: nil, DisableKeepAlives: true}}
	resp, err := client.Do(req)
	if err != nil {
		return err
	}
	defer resp.Body.Close()
	_, _ = io.Copy(io.Discard, io.LimitReader(resp.Body, 4096))
	if resp.StatusCode != http.StatusOK {
		return fmt.Errorf("GET %s returned %d", url, resp.StatusCode)
	}
	return nil
}
