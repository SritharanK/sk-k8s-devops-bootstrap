package config

import (
	"log/slog"
	"strings"
	"testing"
	"time"
)

func env(m map[string]string) func(string) string {
	return func(k string) string { return m[k] }
}

func TestLoadDefaults(t *testing.T) {
	cfg, err := Load(env(nil))
	if err != nil {
		t.Fatalf("Load() error = %v", err)
	}
	want := Config{
		HTTPAddr:        ":8080",
		LogLevel:        slog.LevelInfo,
		ShutdownDelay:   5 * time.Second,
		ShutdownTimeout: 20 * time.Second,
	}
	if cfg != want {
		t.Fatalf("Load() = %+v, want %+v", cfg, want)
	}
}

func TestLoadOverrides(t *testing.T) {
	cfg, err := Load(env(map[string]string{
		EnvHTTPAddr:        "127.0.0.1:9090",
		EnvLogLevel:        " DEBUG ",
		EnvShutdownDelay:   "0s",
		EnvShutdownTimeout: "10s",
	}))
	if err != nil {
		t.Fatalf("Load() error = %v", err)
	}
	want := Config{
		HTTPAddr:        "127.0.0.1:9090",
		LogLevel:        slog.LevelDebug,
		ShutdownDelay:   0,
		ShutdownTimeout: 10 * time.Second,
	}
	if cfg != want {
		t.Fatalf("Load() = %+v, want %+v", cfg, want)
	}
}

func TestLoadLogLevels(t *testing.T) {
	for in, want := range map[string]slog.Level{
		"debug": slog.LevelDebug,
		"info":  slog.LevelInfo,
		"warn":  slog.LevelWarn,
		"error": slog.LevelError,
	} {
		cfg, err := Load(env(map[string]string{EnvLogLevel: in}))
		if err != nil {
			t.Fatalf("Load(LOG_LEVEL=%s) error = %v", in, err)
		}
		if cfg.LogLevel != want {
			t.Errorf("Load(LOG_LEVEL=%s).LogLevel = %v, want %v", in, cfg.LogLevel, want)
		}
	}
}

func TestLoadInvalid(t *testing.T) {
	tests := []struct {
		name    string
		env     map[string]string
		wantErr []string
	}{
		{
			name:    "invalid log level",
			env:     map[string]string{EnvLogLevel: "verbose"},
			wantErr: []string{"LOG_LEVEL", `unknown level "verbose"`},
		},
		{
			name:    "invalid delay duration",
			env:     map[string]string{EnvShutdownDelay: "5"},
			wantErr: []string{"SHUTDOWN_DELAY", "invalid duration"},
		},
		{
			name:    "invalid timeout duration",
			env:     map[string]string{EnvShutdownTimeout: "soon"},
			wantErr: []string{"SHUTDOWN_TIMEOUT", "invalid duration"},
		},
		{
			name:    "negative delay",
			env:     map[string]string{EnvShutdownDelay: "-1s"},
			wantErr: []string{"SHUTDOWN_DELAY", "must not be negative"},
		},
		{
			name:    "zero timeout",
			env:     map[string]string{EnvShutdownTimeout: "0s"},
			wantErr: []string{"SHUTDOWN_TIMEOUT", "must be positive"},
		},
		{
			name:    "timeout reaches grace period",
			env:     map[string]string{EnvShutdownDelay: "0s", EnvShutdownTimeout: "30s"},
			wantErr: []string{"termination grace period"},
		},
		{
			name:    "delay plus timeout exceeds grace period",
			env:     map[string]string{EnvShutdownDelay: "15s", EnvShutdownTimeout: "20s"},
			wantErr: []string{"SHUTDOWN_DELAY (15s) + SHUTDOWN_TIMEOUT (20s)", "termination grace period"},
		},
		{
			name:    "address without port",
			env:     map[string]string{EnvHTTPAddr: "localhost"},
			wantErr: []string{"HTTP_ADDR", "invalid listen address"},
		},
		{
			name:    "port zero",
			env:     map[string]string{EnvHTTPAddr: ":0"},
			wantErr: []string{"HTTP_ADDR", "invalid port"},
		},
		{
			name:    "non-numeric port",
			env:     map[string]string{EnvHTTPAddr: ":http"},
			wantErr: []string{"HTTP_ADDR", "invalid port"},
		},
		{
			name: "all errors are reported together",
			env: map[string]string{
				EnvHTTPAddr:      "nope",
				EnvLogLevel:      "loud",
				EnvShutdownDelay: "later",
			},
			wantErr: []string{"HTTP_ADDR", "LOG_LEVEL", "SHUTDOWN_DELAY"},
		},
	}
	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			_, err := Load(env(tt.env))
			if err == nil {
				t.Fatal("Load() error = nil, want error")
			}
			for _, s := range tt.wantErr {
				if !strings.Contains(err.Error(), s) {
					t.Errorf("Load() error = %q, want it to contain %q", err, s)
				}
			}
		})
	}
}

func TestPort(t *testing.T) {
	tests := map[string]int{
		":8080":          8080,
		"0.0.0.0:80":     80,
		"[::]:65535":     65535,
		"127.0.0.1:1234": 1234,
	}
	for addr, want := range tests {
		got, err := Port(addr)
		if err != nil || got != want {
			t.Errorf("Port(%q) = %d, %v, want %d, nil", addr, got, err, want)
		}
	}
	for _, addr := range []string{"", "8080", ":65536", ":-1"} {
		if _, err := Port(addr); err == nil {
			t.Errorf("Port(%q) error = nil, want error", addr)
		}
	}
}
