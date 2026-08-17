package api

import (
	"net/http"
	"os"
	"path/filepath"

	"github.com/enegalan/calf/backend/internal/daemon"
	"github.com/enegalan/calf/backend/internal/dockercli"
	"github.com/enegalan/calf/backend/internal/httpkit"
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
