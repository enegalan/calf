package config_test

import (
	"strings"
	"testing"

	"github.com/enegalan/calf/backend/internal/config"
)

func TestValidateProxyUpdateNoProxyCIDR(t *testing.T) {
	cidr := "192.168.0.0/16"
	req := config.UpdateRequest{NoProxy: &cidr}
	if err := config.ValidateProxyUpdate(req); err != nil {
		t.Fatalf("ValidateProxyUpdate() error: %v", err)
	}
}

func TestValidateProxyUpdateNoProxyInvalidPath(t *testing.T) {
	entry := "example.com/path"
	req := config.UpdateRequest{NoProxy: &entry}
	err := config.ValidateProxyUpdate(req)
	if err == nil {
		t.Fatal("expected error for path-like no_proxy entry")
	}
	if !strings.Contains(err.Error(), "must not contain a path") {
		t.Fatalf("expected path error, got: %v", err)
	}
}

func TestValidateProxyUpdateNoProxyInvalidCIDR(t *testing.T) {
	entry := "192.168.0.0/33"
	req := config.UpdateRequest{NoProxy: &entry}
	err := config.ValidateProxyUpdate(req)
	if err == nil {
		t.Fatal("expected error for invalid CIDR no_proxy entry")
	}
	if !strings.Contains(err.Error(), "must not contain a path") {
		t.Fatalf("expected path error for invalid CIDR, got: %v", err)
	}
}

func TestValidateResourceUpdateWithinBounds(t *testing.T) {
	cpus := 4
	memoryGB := 8
	swapGB := 4
	req := config.UpdateRequest{
		CPUs:         &cpus,
		MemoryGB:     &memoryGB,
		MemorySwapGB: &swapGB,
	}
	if err := config.ValidateResourceUpdate(req, 8, 16); err != nil {
		t.Fatalf("ValidateResourceUpdate() error: %v", err)
	}
}

func TestValidateResourceUpdateCPUsOutOfRange(t *testing.T) {
	cpus := 32
	req := config.UpdateRequest{CPUs: &cpus}
	err := config.ValidateResourceUpdate(req, 8, 16)
	if err == nil {
		t.Fatal("expected error for cpus above host capacity")
	}
	if !strings.Contains(err.Error(), "cpus:") {
		t.Fatalf("expected cpus error, got: %v", err)
	}
}
