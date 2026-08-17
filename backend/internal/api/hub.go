package api

import (
	"context"
	"encoding/json"
	"fmt"
	"io"
	"net/http"
	"net/url"
	"strings"
	"time"

	"github.com/enegalan/calf/backend/internal/constants"
	"github.com/enegalan/calf/backend/internal/httpkit"
)

// hubRepository is one Docker Hub repository owned by the signed-in user.
type hubRepository struct {
	Name        string `json:"name"`
	Namespace   string `json:"namespace"`
	Description string `json:"description"`
	StarCount   int    `json:"star_count"`
	PullCount   int    `json:"pull_count"`
	IsPrivate   bool   `json:"is_private"`
}

// handleHubRepositories serves GET /v1/hub/repositories for the signed-in Docker Hub user.
func (g *Gateway) handleHubRepositories(w http.ResponseWriter, r *http.Request) {
	r, cancel := httpkit.WithTimeout(r, constants.DefaultActionTimeout)
	defer cancel()

	status, err := g.backend.Runtime.RegistryStatus(r.Context())
	if err != nil {
		httpkit.WriteRuntimeOrFail(w, err)
		return
	}
	if !status.LoggedIn || strings.TrimSpace(status.Username) == "" {
		httpkit.WriteError(w, http.StatusUnauthorized, "sign in to Docker Hub first")
		return
	}

	repos, err := fetchHubRepositories(r.Context(), status.Username)
	if err != nil {
		httpkit.WriteError(w, http.StatusBadGateway, err.Error())
		return
	}
	httpkit.WriteJSON(w, http.StatusOK, repos)
}

type hubListResponse struct {
	Results []struct {
		Name        string `json:"name"`
		Namespace   string `json:"namespace"`
		Description string `json:"description"`
		StarCount   int    `json:"star_count"`
		PullCount   int    `json:"pull_count"`
		IsPrivate   bool   `json:"is_private"`
	} `json:"results"`
}

// fetchHubRepositories lists public Hub repositories for username.
func fetchHubRepositories(_ context.Context, username string) ([]hubRepository, error) {
	endpoint := "https://hub.docker.com/v2/repositories/" + url.PathEscape(username) + "/?page_size=25"
	req, err := http.NewRequest(http.MethodGet, endpoint, nil)
	if err != nil {
		return nil, err
	}
	client := &http.Client{Timeout: 15 * time.Second}
	resp, err := client.Do(req)
	if err != nil {
		return nil, fmt.Errorf("docker hub: %w", err)
	}
	defer resp.Body.Close()
	if resp.StatusCode >= 300 {
		body, _ := io.ReadAll(io.LimitReader(resp.Body, 512))
		return nil, fmt.Errorf("docker hub status %d: %s", resp.StatusCode, strings.TrimSpace(string(body)))
	}
	var parsed hubListResponse
	if err := json.NewDecoder(resp.Body).Decode(&parsed); err != nil {
		return nil, fmt.Errorf("decode docker hub response: %w", err)
	}
	out := make([]hubRepository, 0, len(parsed.Results))
	for _, row := range parsed.Results {
		ns := row.Namespace
		if ns == "" {
			ns = username
		}
		out = append(out, hubRepository{
			Name:        row.Name,
			Namespace:   ns,
			Description: row.Description,
			StarCount:   row.StarCount,
			PullCount:   row.PullCount,
			IsPrivate:   row.IsPrivate,
		})
	}
	return out, nil
}
