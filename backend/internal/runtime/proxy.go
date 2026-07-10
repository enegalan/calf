package runtime

import (
	"context"
	"fmt"
	"strings"
)

type ProxyConfig struct {
	HTTPProxy  string
	HTTPSProxy string
	NoProxy    string
}

// applyProxyInVM writes HTTP proxy settings into the Lima VM so containerd, Docker, and shell sessions inherit them.
func applyProxyInVM(ctx context.Context, run commandRunner, proxy ProxyConfig) error {
	httpProxyDQ := shellDoubleQuote(proxy.HTTPProxy)
	httpsProxyDQ := shellDoubleQuote(proxy.HTTPSProxy)
	noProxyDQ := shellDoubleQuote(proxy.NoProxy)

	httpProxySQ := shellQuote(proxy.HTTPProxy)
	httpsProxySQ := shellQuote(proxy.HTTPSProxy)
	noProxySQ := shellQuote(proxy.NoProxy)

	script := fmt.Sprintf(`set -eux -o pipefail
sudo mkdir -p /etc/systemd/system/containerd.service.d
sudo tee /etc/systemd/system/containerd.service.d/calf-proxy.conf >/dev/null <<'EOF'
[Service]
Environment="HTTP_PROXY=%s"
Environment="HTTPS_PROXY=%s"
Environment="NO_PROXY=%s"
Environment="http_proxy=%s"
Environment="https_proxy=%s"
Environment="no_proxy=%s"
EOF
sudo tee /etc/profile.d/calf-proxy.sh >/dev/null <<'EOF'
export HTTP_PROXY='%s'
export HTTPS_PROXY='%s'
export NO_PROXY='%s'
export http_proxy='%s'
export https_proxy='%s'
export no_proxy='%s'
EOF
sudo systemctl daemon-reload
if systemctl is-active --quiet containerd; then
  sudo systemctl restart containerd
fi
if systemctl is-active --quiet docker; then
  sudo systemctl restart docker
fi
`,
		httpProxyDQ, httpsProxyDQ, noProxyDQ, httpProxyDQ, httpsProxyDQ, noProxyDQ,
		httpProxySQ, httpsProxySQ, noProxySQ, httpProxySQ, httpsProxySQ, noProxySQ,
	)

	_, err := run(ctx, "bash", "-lc", script)
	return err
}

// shellQuote escapes a value for use inside single-quoted shell strings.
func shellQuote(value string) string {
	value = strings.TrimSpace(value)
	if value == "" {
		return ""
	}

	return strings.ReplaceAll(value, "'", "'\\''")
}

// shellDoubleQuote escapes a value for use inside double-quoted shell strings.
func shellDoubleQuote(value string) string {
	value = strings.TrimSpace(value)
	if value == "" {
		return ""
	}

	value = strings.ReplaceAll(value, "\\", "\\\\")
	value = strings.ReplaceAll(value, "\"", "\\\"")
	value = strings.ReplaceAll(value, "$", "\\$")
	return value
}
