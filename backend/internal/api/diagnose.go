package api

import (
	"io"
	"net/http"
	"os"
	"path/filepath"

	"github.com/enegalan/calf/backend/internal/config"
	"github.com/enegalan/calf/backend/internal/constants"
	"github.com/enegalan/calf/backend/internal/daemon"
	"github.com/enegalan/calf/backend/internal/dockercli"
	"github.com/enegalan/calf/backend/internal/httpkit"
	"github.com/enegalan/calf/backend/internal/runtime"
	"github.com/enegalan/calf/backend/internal/utils"
)

// handleDockerCLIInstall serves POST /v1/docker-cli/install.
func (g *Gateway) handleDockerCLIInstall(w http.ResponseWriter, r *http.Request) {
	if err := dockercli.InstallCLI(); err != nil {
		httpkit.WriteError(w, http.StatusBadRequest, err.Error())
		return
	}
	utils.WriteOK(w)
}

// handleTroubleshootDiagnose serves GET /v1/troubleshoot/diagnose as a zip download.
func (g *Gateway) handleTroubleshootDiagnose(w http.ResponseWriter, r *http.Request) {
	path, err := daemon.WriteDiagnosticsBundle("")
	if err != nil {
		httpkit.WriteLoggedError(g.logger, w, http.StatusInternalServerError, "failed to create diagnostics zip", err)
		return
	}
	data, err := os.ReadFile(path)
	if err != nil {
		httpkit.WriteLoggedError(g.logger, w, http.StatusInternalServerError, "failed to read diagnostics zip", err)
		return
	}
	w.Header().Set("Content-Type", "application/zip")
	w.Header().Set("Content-Disposition", `attachment; filename="`+filepath.Base(path)+`"`)
	w.WriteHeader(http.StatusOK)
	_, _ = w.Write(data)
}

// handleDiskImageCopy serves POST /v1/config/disk-image/copy to copy the VM disk while stopped.
func (g *Gateway) handleDiskImageCopy(w http.ResponseWriter, r *http.Request) {
	r, cancel := httpkit.WithTimeout(r, constants.TroubleshootActionTimeout)
	defer cancel()

	var payload struct {
		Path string `json:"path"`
	}
	if !httpkit.JSONDecodeOrFail(w, r, &payload) {
		return
	}
	if !httpkit.RequireNonEmpty(w, "path", payload.Path) {
		return
	}
	status, err := g.backend.Runtime.Status(r.Context())
	if err != nil {
		httpkit.WriteRuntimeOrFail(w, err)
		return
	}
	if status.State != runtime.State(constants.RuntimeStateStopped) {
		httpkit.WriteError(w, http.StatusConflict, "stop the engine before copying the disk image")
		return
	}
	g.backend.CfgMu.RLock()
	src := config.EffectiveDiskImage(g.backend.Cfg)
	g.backend.CfgMu.RUnlock()
	dest := config.ExpandHomePath(payload.Path)
	if err := copyDiskImageFile(src, dest); err != nil {
		httpkit.WriteLoggedError(g.logger, w, http.StatusInternalServerError, "failed to copy disk image", err)
		return
	}
	utils.WriteOK(w)
}

// copyDiskImageFile copies src to dest, creating parent directories as needed.
func copyDiskImageFile(src, dest string) error {
	in, err := os.Open(src)
	if err != nil {
		return err
	}
	defer in.Close()
	if err := os.MkdirAll(filepath.Dir(dest), 0o755); err != nil {
		return err
	}
	out, err := os.Create(dest)
	if err != nil {
		return err
	}
	defer out.Close()
	if _, err := io.Copy(out, in); err != nil {
		return err
	}
	return out.Close()
}
