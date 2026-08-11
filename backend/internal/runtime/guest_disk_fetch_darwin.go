//go:build darwin

package runtime

import (
	"context"
	"encoding/json"
	"fmt"
	"io"
	"net/http"
	"os"
	"os/exec"
	"path/filepath"
	"runtime"
	"strings"
	"syscall"
	"time"

	"github.com/enegalan/calf/backend/internal/constants"
	"github.com/enegalan/calf/backend/version"
	"github.com/klauspost/compress/zstd"
)

// guestDiskArch returns the release asset arch suffix (arm64 or amd64).
// Uses the host machine arch (uname), not runtime.GOARCH, so a Rosetta
// (x86_64) Go toolchain on Apple Silicon still fetches arm64 guest disks.
func guestDiskArch() string {
	if out, err := exec.Command("uname", "-m").Output(); err == nil {
		switch strings.TrimSpace(string(out)) {
		case "arm64", "aarch64":
			return "arm64"
		case "x86_64", "amd64":
			return "amd64"
		}
	}
	switch runtime.GOARCH {
	case "arm64":
		return "arm64"
	default:
		return "amd64"
	}
}

// guestDiskAssetName is the GitHub Release asset name for the compressed guest disk.
func guestDiskAssetName() string {
	return fmt.Sprintf("%s-%s.raw.zst", constants.GuestDiskAssetPrefix, guestDiskArch())
}

// guestEFIAssetName is the optional compressed EFI variable store asset name.
func guestEFIAssetName() string {
	return fmt.Sprintf("%s-%s.zst", constants.GuestEFIAssetPrefix, guestDiskArch())
}

// decompressZstdFile writes a zstd archive to destPath using a pure-Go decoder.
func decompressZstdFile(srcPath, destPath string) error {
	in, err := os.Open(srcPath)
	if err != nil {
		return err
	}
	defer in.Close()
	decoder, err := zstd.NewReader(in)
	if err != nil {
		return err
	}
	defer decoder.Close()
	tmp := destPath + ".partial"
	out, err := os.OpenFile(tmp, os.O_CREATE|os.O_WRONLY|os.O_TRUNC, 0o644)
	if err != nil {
		return err
	}
	if _, err := io.Copy(out, decoder); err != nil {
		_ = out.Close()
		_ = os.Remove(tmp)
		return err
	}
	if err := out.Close(); err != nil {
		_ = os.Remove(tmp)
		return err
	}
	return os.Rename(tmp, destPath)
}

// extractGuestSeed decompresses seed (.zst) into disk.raw (and optional efi-store).
func (v *Guest) extractGuestSeed(seed string) error {
	if err := decompressZstdFile(seed, v.diskPath()); err != nil {
		return fmt.Errorf("extract guest disk from %s: %w", seed, err)
	}
	efiSeed := ""
	if strings.HasSuffix(seed, "disk.raw.zst") {
		efiSeed = strings.TrimSuffix(seed, "disk.raw.zst") + "efi-store.zst"
	}
	base := filepath.Base(seed)
	if strings.HasPrefix(base, constants.GuestDiskAssetPrefix) {
		efiSeed = filepath.Join(filepath.Dir(seed), guestEFIAssetName())
	}
	if efiSeed != "" {
		if _, err := os.Stat(efiSeed); err == nil {
			_ = decompressZstdFile(efiSeed, v.efiPath())
		}
	}
	return nil
}

// downloadGuestDisk fetches the compressed guest disk from GitHub Releases into dataDir.
func (v *Guest) downloadGuestDisk(ctx context.Context) (string, error) {
	if strings.TrimSpace(os.Getenv("CALF_GUEST_NO_DOWNLOAD")) == "1" {
		return "", fmt.Errorf("guest disk download disabled (CALF_GUEST_NO_DOWNLOAD=1)")
	}
	dest := filepath.Join(v.dataDir, guestDiskAssetName())
	url := strings.TrimSpace(os.Getenv("CALF_GUEST_DISK_URL"))
	if url == "" {
		var err error
		url, err = resolveGuestDiskDownloadURL(ctx)
		if err != nil {
			return "", err
		}
	}
	if err := downloadFile(ctx, url, dest); err != nil {
		return "", fmt.Errorf("download guest disk: %w", err)
	}
	efiURL := strings.TrimSpace(os.Getenv("CALF_GUEST_EFI_URL"))
	if efiURL == "" {
		efiURL = strings.Replace(url, guestDiskAssetName(), guestEFIAssetName(), 1)
	}
	efiDest := filepath.Join(v.dataDir, guestEFIAssetName())
	if err := downloadFile(ctx, efiURL, efiDest); err != nil {
		// EFI store is optional; older releases may omit it.
		_ = os.Remove(efiDest)
	}
	return dest, nil
}

type githubReleaseAsset struct {
	Name               string `json:"name"`
	BrowserDownloadURL string `json:"browser_download_url"`
}

type githubRelease struct {
	TagName string               `json:"tag_name"`
	Assets  []githubReleaseAsset `json:"assets"`
}

// resolveGuestDiskDownloadURL finds calf-guest-disk-* for this version, else latest, else any recent release.
func resolveGuestDiskDownloadURL(ctx context.Context) (string, error) {
	want := guestDiskAssetName()
	tag := "v" + version.Version
	var lastErr error
	if url, err := releaseAssetURL(ctx, tag, want); err == nil {
		return url, nil
	} else {
		lastErr = err
	}
	if url, err := latestReleaseAssetURL(ctx, want); err == nil {
		return url, nil
	} else {
		lastErr = err
	}
	if url, err := anyReleaseAssetURL(ctx, want); err == nil {
		return url, nil
	} else {
		lastErr = err
	}
	return "", fmt.Errorf("no GitHub release asset %q for v%s or recent releases: %w", want, version.Version, lastErr)
}

func releaseAssetURL(ctx context.Context, tag, assetName string) (string, error) {
	api := fmt.Sprintf("https://api.github.com/repos/%s/releases/tags/%s", constants.GitHubRepo, tag)
	var rel githubRelease
	if err := getJSON(ctx, api, &rel); err != nil {
		return "", err
	}
	for _, a := range rel.Assets {
		if a.Name == assetName && a.BrowserDownloadURL != "" {
			return a.BrowserDownloadURL, nil
		}
	}
	return "", fmt.Errorf("asset %s not in release %s", assetName, tag)
}

func latestReleaseAssetURL(ctx context.Context, assetName string) (string, error) {
	api := fmt.Sprintf("https://api.github.com/repos/%s/releases/latest", constants.GitHubRepo)
	var rel githubRelease
	if err := getJSON(ctx, api, &rel); err != nil {
		return "", err
	}
	for _, a := range rel.Assets {
		if a.Name == assetName && a.BrowserDownloadURL != "" {
			return a.BrowserDownloadURL, nil
		}
	}
	return "", fmt.Errorf("asset %s not in latest release %s", assetName, rel.TagName)
}

// anyReleaseAssetURL scans recent GitHub Releases for assetName (newest first).
func anyReleaseAssetURL(ctx context.Context, assetName string) (string, error) {
	api := fmt.Sprintf("https://api.github.com/repos/%s/releases?per_page=30", constants.GitHubRepo)
	var releases []githubRelease
	if err := getJSON(ctx, api, &releases); err != nil {
		return "", err
	}
	for _, rel := range releases {
		for _, a := range rel.Assets {
			if a.Name == assetName && a.BrowserDownloadURL != "" {
				return a.BrowserDownloadURL, nil
			}
		}
	}
	return "", fmt.Errorf("asset %s not found in recent releases", assetName)
}

func getJSON(ctx context.Context, url string, dest any) error {
	req, err := http.NewRequestWithContext(ctx, http.MethodGet, url, nil)
	if err != nil {
		return err
	}
	req.Header.Set("Accept", "application/vnd.github+json")
	req.Header.Set("User-Agent", "calf/"+version.Version)
	client := &http.Client{Timeout: 30 * time.Second}
	res, err := client.Do(req)
	if err != nil {
		return err
	}
	defer res.Body.Close()
	if res.StatusCode != http.StatusOK {
		body, _ := io.ReadAll(io.LimitReader(res.Body, 512))
		return fmt.Errorf("%s: HTTP %d %s", url, res.StatusCode, strings.TrimSpace(string(body)))
	}
	return json.NewDecoder(res.Body).Decode(dest)
}

func downloadFile(ctx context.Context, url, destPath string) error {
	req, err := http.NewRequestWithContext(ctx, http.MethodGet, url, nil)
	if err != nil {
		return err
	}
	req.Header.Set("User-Agent", "calf/"+version.Version)
	client := &http.Client{Timeout: 45 * time.Minute}
	res, err := client.Do(req)
	if err != nil {
		return err
	}
	defer res.Body.Close()
	if res.StatusCode != http.StatusOK {
		body, _ := io.ReadAll(io.LimitReader(res.Body, 512))
		return fmt.Errorf("%s: HTTP %d %s", url, res.StatusCode, strings.TrimSpace(string(body)))
	}
	tmp := destPath + ".partial"
	out, err := os.OpenFile(tmp, os.O_CREATE|os.O_WRONLY|os.O_TRUNC, 0o644)
	if err != nil {
		return err
	}
	if _, err := io.Copy(out, res.Body); err != nil {
		_ = out.Close()
		_ = os.Remove(tmp)
		return err
	}
	if err := out.Close(); err != nil {
		_ = os.Remove(tmp)
		return err
	}
	return os.Rename(tmp, destPath)
}

// ensureHostSpaceForGuestExtract checks free space before decompressing the guest disk seed.
func ensureHostSpaceForGuestExtract(dataDir, seed string) error {
	required := guestDiskUncompressedBytes(seed)
	if required <= 0 {
		required = constants.GuestDiskMinFreeBytes
	}
	free, ok := hostVolumeAvailableBytes(dataDir)
	if !ok {
		return nil
	}
	if free >= required {
		return nil
	}
	return fmt.Errorf(
		"not enough free disk space to extract the guest disk: need ~%s free, have %s. Free space on this Mac and retry (Docker Desktop data under ~/Library/Containers/com.docker.docker is often large)",
		formatByteSize(required),
		formatByteSize(free),
	)
}

// guestDiskUncompressedBytes reads the zstd frame content size from seed, or 0 if unknown.
func guestDiskUncompressedBytes(seed string) int64 {
	f, err := os.Open(seed)
	if err != nil {
		return 0
	}
	defer f.Close()
	hdr := make([]byte, 128)
	n, err := io.ReadFull(f, hdr)
	if err != nil && err != io.ErrUnexpectedEOF && err != io.EOF {
		return 0
	}
	if n == 0 {
		return 0
	}
	var h zstd.Header
	if err := h.Decode(hdr[:n]); err != nil || !h.HasFCS {
		return 0
	}
	if h.FrameContentSize == 0 || h.FrameContentSize > 1<<46 {
		return 0
	}
	return int64(h.FrameContentSize)
}

// hostVolumeAvailableBytes returns free bytes on the volume containing path.
func hostVolumeAvailableBytes(path string) (int64, bool) {
	var st syscall.Statfs_t
	if err := syscall.Statfs(path, &st); err != nil {
		return 0, false
	}
	return int64(st.Bavail) * int64(st.Bsize), true
}

// formatByteSize renders a compact human size for errors.
func formatByteSize(size int64) string {
	if size < 1024 {
		return fmt.Sprintf("%d B", size)
	}
	units := []string{"KiB", "MiB", "GiB", "TiB"}
	v := float64(size)
	for _, u := range units {
		v /= 1024
		if v < 1024 {
			return fmt.Sprintf("%.1f %s", v, u)
		}
	}
	return fmt.Sprintf("%.1f PiB", v/1024)
}
