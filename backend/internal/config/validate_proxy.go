package config

import (
	"fmt"
	"net"
	"net/url"
	"strings"
)

// UpdateRequest is the subset of config fields accepted by PUT /v1/config.
type UpdateRequest struct {
	CPUs                 *int    `json:"cpus,omitempty"`
	MemoryGB             *int    `json:"memory_gb,omitempty"`
	MemorySwapGB         *int    `json:"memory_swap_gb,omitempty"`
	DockerContextManaged *bool   `json:"docker_context_managed,omitempty"`
	HTTPProxy            *string `json:"http_proxy,omitempty"`
	HTTPSProxy           *string `json:"https_proxy,omitempty"`
	NoProxy              *string `json:"no_proxy,omitempty"`
}

// ValidateProxyUpdate checks http_proxy, https_proxy, and no_proxy fields in a config update request.
func ValidateProxyUpdate(req UpdateRequest) error {
	if req.HTTPProxy != nil {
		v := strings.TrimSpace(*req.HTTPProxy)
		if v != "" {
			if err := validateProxyURL(v, "http"); err != nil {
				return fmt.Errorf("http_proxy: %w", err)
			}
		}
	}
	if req.HTTPSProxy != nil {
		v := strings.TrimSpace(*req.HTTPSProxy)
		if v != "" {
			if err := validateProxyURL(v, "http", "https"); err != nil {
				return fmt.Errorf("https_proxy: %w", err)
			}
		}
	}
	if req.NoProxy != nil {
		v := strings.TrimSpace(*req.NoProxy)
		if v != "" {
			for _, entry := range strings.Split(v, ",") {
				entry = strings.TrimSpace(entry)
				if entry != "" {
					if err := validateNoProxyEntry(entry); err != nil {
						return fmt.Errorf("no_proxy: %w", err)
					}
				}
			}
		}
	}
	return nil
}

// validateProxyURL validates a proxy URL against a list of allowed schemes.
func validateProxyURL(raw string, allowedSchemes ...string) error {
	u, err := url.Parse(raw)
	if err != nil {
		return fmt.Errorf("invalid URL %q: %w", raw, err)
	}

	if u.Scheme == "" {
		return fmt.Errorf("missing scheme in %q (expected http:// or https://)", raw)
	}

	schemeOK := false
	for _, s := range allowedSchemes {
		if u.Scheme == s {
			schemeOK = true
			break
		}
	}
	if !schemeOK {
		return fmt.Errorf("unsupported scheme %q in %q", u.Scheme, raw)
	}

	if u.Host == "" {
		return fmt.Errorf("missing host in %q", raw)
	}

	return nil
}

func validateNoProxyEntry(entry string) error {
	if strings.Contains(entry, "/") {
		return fmt.Errorf("invalid no_proxy entry %q: must not contain a path", entry)
	}

	host := strings.TrimPrefix(entry, ".")

	if net.ParseIP(host) != nil {
		return nil
	}

	if h, _, err := net.SplitHostPort(host); err == nil {
		if net.ParseIP(h) != nil {
			return nil
		}
		host = h
	}

	if isValidDomain(host) {
		return nil
	}

	return fmt.Errorf("invalid no_proxy entry %q: must be a valid hostname or IP address", entry)
}

func isValidDomain(host string) bool {
	if host == "" || len(host) > 253 {
		return false
	}

	for _, part := range strings.Split(host, ".") {
		if part == "" || len(part) > 63 {
			return false
		}
		for i, r := range part {
			if i == 0 && r == '-' {
				return false
			}
			if i == len(part)-1 && r == '-' {
				return false
			}
			if !((r >= 'a' && r <= 'z') || (r >= 'A' && r <= 'Z') ||
				(r >= '0' && r <= '9') || r == '-' || r == '_') {
				return false
			}
		}
	}

	return true
}
