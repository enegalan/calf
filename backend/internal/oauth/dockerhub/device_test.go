package dockerhub_test

import (
	"context"
	"encoding/base64"
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"testing"
	"time"

	"github.com/enegalan/calf/backend/internal/oauth/dockerhub"
)

func TestStartDeviceLogin(t *testing.T) {
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.URL.Path != "/oauth/device/code" {
			t.Fatalf("unexpected path: %s", r.URL.Path)
		}

		_ = json.NewEncoder(w).Encode(map[string]any{
			"device_code":               "device-123",
			"user_code":                 "ABCD-EFGH",
			"verification_uri_complete": "https://login.docker.com/activate?code=ABCD-EFGH",
			"expires_in":                600,
			"interval":                  1,
		})
	}))
	defer server.Close()

	client := dockerhub.NewClient()
	client.HTTP = server.Client()
	client.TenantURL = server.URL

	state, err := client.StartDeviceLogin(context.Background())
	if err != nil {
		t.Fatalf("StartDeviceLogin() error: %v", err)
	}

	if state.UserCode != "ABCD-EFGH" {
		t.Fatalf("unexpected user code: %q", state.UserCode)
	}
}

func TestUsernameFromAccessToken(t *testing.T) {
	claims := map[string]any{
		"https://hub.docker.com": map[string]string{
			"username": "demo",
			"email":    "demo@example.com",
		},
	}
	payload, err := json.Marshal(claims)
	if err != nil {
		t.Fatalf("marshal claims: %v", err)
	}

	token := "header." + base64.RawURLEncoding.EncodeToString(payload) + ".signature"
	username, err := dockerhub.UsernameFromAccessToken(token)
	if err != nil {
		t.Fatalf("UsernameFromAccessToken() error: %v", err)
	}
	if username != "demo" {
		t.Fatalf("expected demo, got %q", username)
	}
}

func TestWaitForDeviceTokenCompletes(t *testing.T) {
	requests := 0
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.URL.Path != "/oauth/token" {
			t.Fatalf("unexpected path: %s", r.URL.Path)
		}

		requests++
		if requests < 2 {
			_ = json.NewEncoder(w).Encode(map[string]any{
				"error":             "authorization_pending",
				"error_description": "authorization_pending",
			})
			return
		}

		claims := map[string]any{
			"https://hub.docker.com": map[string]string{"username": "demo"},
		}
		payload, _ := json.Marshal(claims)
		_ = json.NewEncoder(w).Encode(map[string]any{
			"access_token": "header." + base64.RawURLEncoding.EncodeToString(payload) + ".sig",
		})
	}))
	defer server.Close()

	client := dockerhub.NewClient()
	client.HTTP = server.Client()
	client.TenantURL = server.URL

	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()

	token, err := client.WaitForDeviceToken(ctx, dockerhub.DeviceCode{
		DeviceCode: "device-123",
		ExpiresIn:  30,
		Interval:   1,
	})
	if err != nil {
		t.Fatalf("WaitForDeviceToken() error: %v", err)
	}

	username, err := dockerhub.UsernameFromAccessToken(token)
	if err != nil {
		t.Fatalf("UsernameFromAccessToken() error: %v", err)
	}
	if username != "demo" {
		t.Fatalf("expected demo, got %q", username)
	}
}

func TestGeneratePAT(t *testing.T) {
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.URL.Path != "/v2/access-tokens/desktop-generate" {
			t.Fatalf("unexpected path: %s", r.URL.Path)
		}
		if got := r.Header.Get("Authorization"); got != "Bearer access-token" {
			t.Fatalf("unexpected authorization header: %q", got)
		}

		w.WriteHeader(http.StatusCreated)
		_ = json.NewEncoder(w).Encode(map[string]any{
			"data": map[string]string{"token": "dckr_pat_test"},
		})
	}))
	defer server.Close()

	client := dockerhub.NewClient()
	client.HTTP = server.Client()
	client.HubURL = server.URL

	pat, err := client.GeneratePAT(context.Background(), "access-token")
	if err != nil {
		t.Fatalf("GeneratePAT() error: %v", err)
	}
	if pat != "dckr_pat_test" {
		t.Fatalf("unexpected pat: %q", pat)
	}
}
