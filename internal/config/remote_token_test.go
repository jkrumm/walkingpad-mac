package config

import (
	"os"
	"path/filepath"
	"regexp"
	"testing"
)

func TestResolveRemoteToken(t *testing.T) {
	hex64 := regexp.MustCompile(`^[0-9a-f]{64}$`)

	t.Run("configured wins and writes nothing", func(t *testing.T) {
		dir := t.TempDir()
		got, err := ResolveRemoteToken(dir, "from-config")
		if err != nil || got != "from-config" {
			t.Fatalf("got %q, %v", got, err)
		}
		if _, err := os.Stat(filepath.Join(dir, RemoteTokenFile)); !os.IsNotExist(err) {
			t.Errorf("token file must not exist, stat err = %v", err)
		}
	})

	t.Run("first call generates 0600 hex, second reuses", func(t *testing.T) {
		dir := filepath.Join(t.TempDir(), "WalkingPad") // dir does not exist yet
		first, err := ResolveRemoteToken(dir, "")
		if err != nil {
			t.Fatal(err)
		}
		if !hex64.MatchString(first) {
			t.Fatalf("token %q is not 32 bytes of hex", first)
		}
		info, err := os.Stat(filepath.Join(dir, RemoteTokenFile))
		if err != nil {
			t.Fatal(err)
		}
		if perm := info.Mode().Perm(); perm != 0o600 {
			t.Errorf("mode = %o, want 600", perm)
		}
		second, err := ResolveRemoteToken(dir, "")
		if err != nil || second != first {
			t.Errorf("second call = %q, %v; want %q", second, err, first)
		}
	})

	t.Run("empty file is an error, not an empty token", func(t *testing.T) {
		dir := t.TempDir()
		if err := os.WriteFile(filepath.Join(dir, RemoteTokenFile), nil, 0o600); err != nil {
			t.Fatal(err)
		}
		if got, err := ResolveRemoteToken(dir, ""); err == nil {
			t.Errorf("got %q, nil; want an error", got)
		}
	})

	t.Run("existing file is trimmed and reused", func(t *testing.T) {
		dir := t.TempDir()
		if err := os.WriteFile(filepath.Join(dir, RemoteTokenFile), []byte("abc123\n"), 0o600); err != nil {
			t.Fatal(err)
		}
		got, err := ResolveRemoteToken(dir, "")
		if err != nil || got != "abc123" {
			t.Errorf("got %q, %v", got, err)
		}
	})
}

func TestValidate_RemotePort(t *testing.T) {
	tests := []struct {
		name    string
		port    int
		wantErr bool
	}{
		{"off", 0, false},
		{"valid", 7710, false},
		{"negative", -1, true},
		{"too high", 70000, true},
		{"same as http_port", 7706, true},
	}
	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			cfg := Default()
			cfg.Daemon.RemotePort = tt.port
			if err := cfg.Validate(); (err != nil) != tt.wantErr {
				t.Fatalf("Validate() = %v, wantErr %v", err, tt.wantErr)
			}
		})
	}
}

func TestLoad_RemoteEnv(t *testing.T) {
	clearEnv(t)
	t.Setenv("KSWP_REMOTE_PORT", "7710")
	t.Setenv("KSWP_REMOTE_TOKEN", "tok")
	cfg, err := Load("")
	if err != nil {
		t.Fatal(err)
	}
	if cfg.Daemon.RemotePort != 7710 || cfg.Daemon.RemoteToken != "tok" {
		t.Errorf("got %+v", cfg.Daemon)
	}
}
