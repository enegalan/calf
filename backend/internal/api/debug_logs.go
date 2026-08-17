package api

import (
	"net/http"

	"github.com/enegalan/calf/backend/internal/config"
	"github.com/enegalan/calf/backend/internal/constants"
	"github.com/enegalan/calf/backend/internal/httpkit"
)

// debugLogsView is the JSON payload for GET /v1/debug/logs.
type debugLogsView struct {
	Text string `json:"text"`
	Path string `json:"path"`
}

// handleDebugLogs serves GET /v1/debug/logs with the recent daemon log file contents.
func (g *Gateway) handleDebugLogs(w http.ResponseWriter, r *http.Request) {
	text, path, err := config.ReadLogTail(constants.DaemonLogTailBytes)
	if err != nil {
		httpkit.WriteLoggedError(g.logger, w, http.StatusInternalServerError, "failed to read daemon logs", err)
		return
	}

	httpkit.WriteJSON(w, http.StatusOK, debugLogsView{
		Text: text,
		Path: path,
	})
}

// handleDebugLogsClear serves DELETE /v1/debug/logs by emptying the daemon log file.
func (g *Gateway) handleDebugLogsClear(w http.ResponseWriter, r *http.Request) {
	if err := config.ClearLogFile(); err != nil {
		httpkit.WriteLoggedError(g.logger, w, http.StatusInternalServerError, "failed to clear daemon logs", err)
		return
	}

	g.handleDebugLogs(w, r)
}
