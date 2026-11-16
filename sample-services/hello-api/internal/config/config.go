// Package config loads and validates the service configuration from
// environment variables.
package config

import (
	"errors"
	"fmt"
	"log/slog"
	"net"
	"strconv"
	"strings"
	"time"
)

// Environment variable names read by Load.
const (
	EnvHTTPAddr        = "HTTP_ADDR"
	EnvLogLevel        = "LOG_LEVEL"
	EnvShutdownDelay   = "SHUTDOWN_DELAY"
	EnvShutdownTimeout = "SHUTDOWN_TIMEOUT"
)

// Default values applied when a variable is unset or empty.
const (
	DefaultHTTPAddr        = ":8080"
	DefaultLogLevel        = slog.LevelInfo
	DefaultShutdownDelay   = 5 * time.Second
	DefaultShutdownTimeout = 20 * time.Second
)

// TerminationGracePeriod is the default Kubernetes pod grace period. The
// shutdown delay and the shutdown timeout together must stay below it, so the
// process exits on its own before the kubelet sends SIGKILL.
const TerminationGracePeriod = 30 * time.Second

// Config holds the validated runtime configuration.
type Config struct {
	// HTTPAddr is the listen address in host:port form, for example ":8080".
	HTTPAddr string
	// LogLevel is the minimum level written by the JSON logger.
	LogLevel slog.Level
	// ShutdownDelay is the time between failing readiness and closing the
	// listener, so that endpoint controllers remove the pod first.
	ShutdownDelay time.Duration
	// ShutdownTimeout bounds the drain of in-flight requests.
	ShutdownTimeout time.Duration
}

// Load reads the configuration through getenv (usually os.Getenv), applies
// defaults and validates every value. All problems are reported together.
func Load(getenv func(string) string) (Config, error) {
	cfg := Config{
		HTTPAddr:        DefaultHTTPAddr,
		LogLevel:        DefaultLogLevel,
		ShutdownDelay:   DefaultShutdownDelay,
		ShutdownTimeout: DefaultShutdownTimeout,
	}

	var errs []error

	if v := strings.TrimSpace(getenv(EnvHTTPAddr)); v != "" {
		cfg.HTTPAddr = v
	}
	if _, err := Port(cfg.HTTPAddr); err != nil {
		errs = append(errs, fmt.Errorf("%s: %w", EnvHTTPAddr, err))
	}

	if v := strings.TrimSpace(getenv(EnvLogLevel)); v != "" {
		level, err := parseLevel(v)
		if err != nil {
			errs = append(errs, fmt.Errorf("%s: %w", EnvLogLevel, err))
		}
		cfg.LogLevel = level
	}

	delayOK, timeoutOK := true, true
	if v := strings.TrimSpace(getenv(EnvShutdownDelay)); v != "" {
		d, err := time.ParseDuration(v)
		switch {
		case err != nil:
			errs = append(errs, fmt.Errorf("%s: invalid duration %q", EnvShutdownDelay, v))
			delayOK = false
		case d < 0:
			errs = append(errs, fmt.Errorf("%s: must not be negative, got %s", EnvShutdownDelay, d))
			delayOK = false
		}
		cfg.ShutdownDelay = d
	}

	if v := strings.TrimSpace(getenv(EnvShutdownTimeout)); v != "" {
		d, err := time.ParseDuration(v)
		switch {
		case err != nil:
			errs = append(errs, fmt.Errorf("%s: invalid duration %q", EnvShutdownTimeout, v))
			timeoutOK = false
		case d <= 0:
			errs = append(errs, fmt.Errorf("%s: must be positive, got %s", EnvShutdownTimeout, d))
			timeoutOK = false
		}
		cfg.ShutdownTimeout = d
	}

	if delayOK && timeoutOK && cfg.ShutdownDelay+cfg.ShutdownTimeout >= TerminationGracePeriod {
		errs = append(errs, fmt.Errorf("%s (%s) + %s (%s) must be less than the %s termination grace period",
			EnvShutdownDelay, cfg.ShutdownDelay, EnvShutdownTimeout, cfg.ShutdownTimeout, TerminationGracePeriod))
	}

	if len(errs) > 0 {
		return Config{}, errors.Join(errs...)
	}
	return cfg, nil
}

// Port returns the numeric port of a host:port listen address. The port must
// be between 1 and 65535; port 0 is rejected because the health check needs a
// fixed port to probe.
func Port(addr string) (int, error) {
	_, p, err := net.SplitHostPort(addr)
	if err != nil {
		return 0, fmt.Errorf("invalid listen address %q: %w", addr, err)
	}
	port, err := strconv.Atoi(p)
	if err != nil || port < 1 || port > 65535 {
		return 0, fmt.Errorf("invalid port %q in listen address %q", p, addr)
	}
	return port, nil
}

func parseLevel(v string) (slog.Level, error) {
	switch strings.ToLower(v) {
	case "debug":
		return slog.LevelDebug, nil
	case "info":
		return slog.LevelInfo, nil
	case "warn":
		return slog.LevelWarn, nil
	case "error":
		return slog.LevelError, nil
	default:
		return DefaultLogLevel, fmt.Errorf("unknown level %q, expected debug, info, warn or error", v)
	}
}
