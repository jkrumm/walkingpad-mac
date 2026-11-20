package config

import (
	"crypto/rand"
	"encoding/hex"
	"errors"
	"fmt"
	"io/fs"
	"os"
	"path/filepath"
	"strings"
)

// RemoteTokenFile is the file name, inside the data dir, of the generated
// bearer token for the remote listener.
const RemoteTokenFile = "remote-token"

// ResolveRemoteToken returns the bearer token the remote listener requires:
// the configured one when set, else the one in <dataDir>/remote-token. A first
// call with neither creates the file with 32 random bytes as hex and mode 0600;
// later calls reuse it. Callers must never log the result.
func ResolveRemoteToken(dataDir, configured string) (string, error) {
	if configured != "" {
		return configured, nil
	}
	path := filepath.Join(dataDir, RemoteTokenFile)

	if tok, err := readTokenFile(path); err != nil || tok != "" {
		return tok, err
	}

	buf := make([]byte, 32)
	if _, err := rand.Read(buf); err != nil {
		return "", fmt.Errorf("generate remote token: %w", err)
	}
	tok := hex.EncodeToString(buf)

	if err := os.MkdirAll(dataDir, 0o700); err != nil {
		return "", fmt.Errorf("create data dir %s: %w", dataDir, err)
	}
	f, err := os.OpenFile(path, os.O_WRONLY|os.O_CREATE|os.O_EXCL, 0o600) // #nosec G304 -- fixed name under the data dir
	if err != nil {
		if errors.Is(err, fs.ErrExist) {
			// Lost a race with another process, or the file exists but is empty.
			return readTokenFile(path)
		}
		return "", fmt.Errorf("create %s: %w", path, err)
	}
	if _, err := f.WriteString(tok + "\n"); err != nil {
		_ = f.Close()
		return "", fmt.Errorf("write %s: %w", path, err)
	}
	if err := f.Close(); err != nil {
		return "", fmt.Errorf("close %s: %w", path, err)
	}
	return tok, nil
}

// readTokenFile returns the trimmed file content, or "" when the file is
// missing or empty.
func readTokenFile(path string) (string, error) {
	raw, err := os.ReadFile(path) // #nosec G304 -- fixed name under the data dir
	if err != nil {
		if errors.Is(err, fs.ErrNotExist) {
			return "", nil
		}
		return "", fmt.Errorf("read %s: %w", path, err)
	}
	return strings.TrimSpace(string(raw)), nil
}
