package config_test

import (
	"path/filepath"
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
	if err := config.ValidateResourceUpdate(req, 8, 16, 500); err != nil {
		t.Fatalf("ValidateResourceUpdate() error: %v", err)
	}
}

func TestValidateResourceUpdateCPUsOutOfRange(t *testing.T) {
	cpus := 32
	req := config.UpdateRequest{CPUs: &cpus}
	err := config.ValidateResourceUpdate(req, 8, 16, 500)
	if err == nil {
		t.Fatal("expected error for cpus above host capacity")
	}
	if !strings.Contains(err.Error(), "cpus:") {
		t.Fatalf("expected cpus error, got: %v", err)
	}
}

func TestValidateResourceUpdateDiskOutOfRange(t *testing.T) {
	diskGB := 1000
	req := config.UpdateRequest{DiskGB: &diskGB}
	err := config.ValidateResourceUpdate(req, 8, 16, 500)
	if err == nil {
		t.Fatal("expected error for disk_gb above host capacity")
	}
	if !strings.Contains(err.Error(), "disk_gb:") {
		t.Fatalf("expected disk_gb error, got: %v", err)
	}
}

func TestValidateResourceUpdateResourceSaverTimeoutOutOfRange(t *testing.T) {
	sec := 10
	req := config.UpdateRequest{ResourceSaverTimeoutSec: &sec}
	err := config.ValidateResourceUpdate(req, 8, 16, 500)
	if err == nil {
		t.Fatal("ValidateResourceUpdate() expected error for timeout below minimum")
	}
}

func TestValidateResourceUpdateResourceSaverTimeoutOK(t *testing.T) {
	sec := 600
	req := config.UpdateRequest{ResourceSaverTimeoutSec: &sec}
	if err := config.ValidateResourceUpdate(req, 8, 16, 500); err != nil {
		t.Fatalf("ValidateResourceUpdate() error: %v", err)
	}
}

func TestValidateResourceUpdateDiskImageRelative(t *testing.T) {
	path := "relative/disk.raw"
	req := config.UpdateRequest{DiskImage: &path}
	err := config.ValidateResourceUpdate(req, 8, 16, 500)
	if err == nil {
		t.Fatal("expected error for relative disk_image path")
	}
	if !strings.Contains(err.Error(), "disk_image:") {
		t.Fatalf("expected disk_image error, got: %v", err)
	}
}

func TestEffectiveDiskImageDefault(t *testing.T) {
	dir := t.TempDir()
	t.Setenv("HOME", dir)

	path := config.EffectiveDiskImage(config.Config{VMName: "calf"})
	want := filepath.Join(dir, ".config", "calf", "guest", "calf", "disk.raw")
	if path != want {
		t.Fatalf("expected %q, got %q", want, path)
	}
}

func TestEffectiveDiskImageOverride(t *testing.T) {
	dir := t.TempDir()
	t.Setenv("HOME", dir)

	custom := filepath.Join(dir, "custom", "disk.raw")
	path := config.EffectiveDiskImage(config.Config{DiskImage: custom})
	if path != custom {
		t.Fatalf("expected %q, got %q", custom, path)
	}
}
