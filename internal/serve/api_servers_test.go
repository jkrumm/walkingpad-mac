package serve

import (
	"io"
	"log/slog"
	"os"
	"path/filepath"
	"testing"

	"github.com/jkrumm/walkingpad-mac/internal/api"
	"github.com/jkrumm/walkingpad-mac/internal/config"
)

func TestNewAPIServers(t *testing.T) {
	log := slog.New(slog.NewTextHandler(io.Discard, nil))
	tests := []struct {
		name       string
		remotePort int
		wantNames  []string
		wantFile   bool
	}{
		{"remote_port 0 starts no second listener", 0, []string{"api"}, false},
		{"remote_port set starts the remote listener", 7710, []string{"api", "api-remote"}, true},
	}
	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			dir := t.TempDir()
			cfg := config.Default()
			cfg.Daemon.RemotePort = tt.remotePort

			got, err := newAPIServers(cfg, dir, "test", api.Deps{}, log)
			if err != nil {
				t.Fatal(err)
			}
			var names []string
			for _, s := range got {
				names = append(names, s.name)
			}
			if len(names) != len(tt.wantNames) {
				t.Fatalf("servers = %v, want %v", names, tt.wantNames)
			}
			for i := range names {
				if names[i] != tt.wantNames[i] {
					t.Fatalf("servers = %v, want %v", names, tt.wantNames)
				}
			}
			_, statErr := os.Stat(filepath.Join(dir, config.RemoteTokenFile))
			if (statErr == nil) != tt.wantFile {
				t.Errorf("token file exists = %v, want %v", statErr == nil, tt.wantFile)
			}
		})
	}
}
