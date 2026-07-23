//go:build darwin

package runtime

import (
	"context"
	"encoding/json"
	"fmt"
	"io"
	"net/http"
	"os"
	"path/filepath"
	"runtime"
	"strings"
	"time"

	"github.com/enegalan/calf/backend/internal/constants"
	"github.com/enegalan/calf/backend/version"
	"github.com/klauspost/compress/zstd"
)

// guestDiskArch returns the release asset arch suffix (arm64 or amd64).
func guestDiskArch() string {
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

// resolveGuestDiskDownloadURL finds the disk asset for this version, else latest.
func resolveGuestDiskDownloadURL(ctx context.Context) (string, error) {
	want := guestDiskAssetName()
	tag := "v" + version.Version
	if url, err := releaseAssetURL(ctx, tag, want); err == nil {
		return url, nil
	}
	url, err := latestReleaseAssetURL(ctx, want)
	if err != nil {
		return "", fmt.Errorf("no GitHub release asset %q for v%s or latest: %w", want, version.Version, err)
	}
	return url, nil
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
