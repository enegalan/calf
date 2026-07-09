package volumeexport_test

import (
	"strings"
	"testing"
	"time"

	"github.com/enegalan/calf/backend/internal/volumeexport"
)

func TestExpandExportNamePattern(t *testing.T) {
	runTime := time.Date(2026, 7, 5, 14, 30, 0, 0, time.UTC)

	expanded := volumeexport.ExpandExportNamePattern("{volume}-{timestamp}.tar.gz", "my/vol", runTime)
	if expanded != "my_vol-20260705-143000.tar.gz" {
		t.Fatalf("unexpected expansion: %q", expanded)
	}

	static := volumeexport.ExpandExportNamePattern("backup.tar.gz", "my/vol", runTime)
	if static != "backup.tar.gz" {
		t.Fatalf("static pattern should be preserved, got %q", static)
	}
}

func TestHasUniqueNameToken(t *testing.T) {
	if !volumeexport.HasUniqueNameToken("{volume}-{timestamp}.tar.gz") {
		t.Fatal("expected timestamp token to be detected")
	}

	if volumeexport.HasUniqueNameToken("backup.tar.gz") {
		t.Fatal("expected static pattern to have no unique token")
	}
}

func TestResolveScheduledExportNames(t *testing.T) {
	runTime := time.Date(2026, 7, 5, 8, 0, 0, 0, time.UTC)
	schedule := volumeexport.Schedule{
		Volume:   "calf-data",
		Type:     volumeexport.TypeLocalFile,
		FileName: "{volume}-{timestamp}.tar.gz",
	}

	fileName, imageRef := volumeexport.ResolveScheduledExportNames(schedule, runTime)
	if imageRef != "" {
		t.Fatalf("expected empty image ref, got %q", imageRef)
	}

	if !strings.HasPrefix(fileName, "calf-data-20260705-080000") {
		t.Fatalf("unexpected resolved file name: %q", fileName)
	}

	staticSchedule := volumeexport.Schedule{
		Volume:   "calf-data",
		Type:     volumeexport.TypeLocalFile,
		FileName: "backup.tar.gz",
	}

	staticName, _ := volumeexport.ResolveScheduledExportNames(staticSchedule, runTime)
	if staticName != "backup.tar.gz" {
		t.Fatalf("static file name should be preserved, got %q", staticName)
	}
}

func TestExpandExportImageRefPattern(t *testing.T) {
	runTime := time.Date(2026, 7, 5, 14, 30, 0, 0, time.UTC)

	expanded := volumeexport.ExpandExportImageRefPattern("{volume}-backup:{timestamp}", "My/Vol", runTime)
	if expanded != "my_vol-backup:20260705-143000" {
		t.Fatalf("unexpected image ref expansion: %q", expanded)
	}
}
