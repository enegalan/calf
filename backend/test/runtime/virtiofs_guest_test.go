//go:build darwin

package runtime_test

import (
	"strings"
	"testing"

	"github.com/enegalan/calf/backend/internal/runtime"
)

// TestVirtiofsGuestSetupScript mounts calf-home and will not delete a mounted $HOME.
func TestVirtiofsGuestSetupScript(t *testing.T) {
	script := runtime.VirtiofsGuestSetupScript("/Users/ada", "", "", true)
	for _, want := range []string{
		"mount -t virtiofs -o noatime calf-home /mnt/calf-home",
		"dax=inode,noatime calf-mounts",
		"HOME_PATH='/Users/ada'",
		`refusing to replace mounted $HOME_PATH`,
		"ln -sfn /mnt/calf-home \"$HOME_PATH\"",
		"calf-mount-virtiofs",
	} {
		if !strings.Contains(script, want) {
			t.Fatalf("script missing %q\n%s", want, script)
		}
	}
	if strings.Contains(script, "rm -rf /mnt/calf-home") {
		t.Fatal("script must not rm -rf the virtiofs home mount point")
	}

	plain := runtime.VirtiofsGuestSetupScript("/Users/ada", "0", "", true)
	if strings.Contains(plain, "dax=inode") {
		t.Fatal("CALF_KRUN_DAX=0 must not remount calf-mounts with dax=inode")
	}
	if !strings.Contains(plain, "mount -t virtiofs -o noatime calf-mounts /mnt/calf") {
		t.Fatal("CALF_KRUN_DAX=0 must mount calf-mounts without DAX")
	}

	skipped := runtime.VirtiofsGuestSetupScript("/Users/ada", "", "", false)
	if strings.Contains(skipped, "exit 1") && strings.Contains(skipped, "calf-home virtiofs mount failed") {
		t.Fatal("unshared home must not fail the guest setup when calf-home is absent")
	}
	if strings.Contains(skipped, "HOME_PATH='/Users/ada'") {
		t.Fatal("unshared home must not point $HOME at calf-home")
	}
}
