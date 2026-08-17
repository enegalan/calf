package daemon

import (
	"archive/zip"
	"encoding/json"
	"fmt"
	"io"
	"os"
	"path/filepath"
	"strings"
	"time"

	"github.com/enegalan/calf/backend/internal/config"
)

// WriteDiagnosticsBundle zips daemon logs, config (proxies redacted), and krunkit.log.
// When out is empty, the zip is written under the system temp directory.
func WriteDiagnosticsBundle(out string) (string, error) {
	if strings.TrimSpace(out) == "" {
		out = filepath.Join(os.TempDir(), fmt.Sprintf("calf-diagnose-%s.zip", time.Now().Format("20060102-150405")))
	}
	file, err := os.Create(out)
	if err != nil {
		return "", fmt.Errorf("create diagnostics zip: %w", err)
	}
	defer file.Close()

	zw := zip.NewWriter(file)
	defer zw.Close()

	if logPath, err := config.LogFilePath(); err == nil {
		_ = addZipFile(zw, logPath, "calf.log")
	}
	if cfgPath, err := config.Path(); err == nil {
		_ = addZipBytes(zw, "config.yaml", redactConfigFile(cfgPath))
	}
	cfg, _ := config.Load()
	guestLog := filepath.Join(filepath.Dir(config.EffectiveDiskImage(cfg)), "krunkit.log")
	_ = addZipFile(zw, guestLog, "krunkit.log")
	meta, _ := json.MarshalIndent(map[string]string{
		"created_at": time.Now().UTC().Format(time.RFC3339),
		"listen":     cfg.ListenAddr,
		"vm_name":    cfg.VMName,
	}, "", "  ")
	_ = addZipBytes(zw, "meta.json", meta)
	if err := zw.Close(); err != nil {
		return "", fmt.Errorf("close diagnostics zip: %w", err)
	}
	return out, nil
}

// addZipFile copies path into the zip as name when the file exists.
func addZipFile(zw *zip.Writer, path, name string) error {
	data, err := os.ReadFile(path)
	if err != nil {
		return err
	}
	return addZipBytes(zw, name, data)
}

// addZipBytes writes data into the zip as name.
func addZipBytes(zw *zip.Writer, name string, data []byte) error {
	w, err := zw.Create(name)
	if err != nil {
		return err
	}
	_, err = w.Write(data)
	return err
}

// redactConfigFile reads a YAML config file and blanks proxy fields.
func redactConfigFile(path string) []byte {
	data, err := os.ReadFile(path)
	if err != nil {
		return []byte("# config unavailable\n")
	}
	text := string(data)
	for _, key := range []string{"http_proxy", "https_proxy"} {
		text = redactYAMLValue(text, key)
	}
	_ = io.Discard
	return []byte(text)
}

// redactYAMLValue replaces the value of a simple key: value line.
func redactYAMLValue(text, key string) string {
	prefix := key + ":"
	lines := strings.Split(text, "\n")
	for i, line := range lines {
		trim := strings.TrimSpace(line)
		if strings.HasPrefix(trim, prefix) {
			indent := line[:len(line)-len(strings.TrimLeft(line, " \t"))]
			lines[i] = indent + prefix + " \"[redacted]\""
		}
	}
	return strings.Join(lines, "\n")
}
