package dockerhub

import (
	"context"
	"encoding/base64"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"net/http"
	"net/url"
	"runtime"
	"strings"
	"time"

	"github.com/enegalan/calf/backend/version"
)

const (
	TenantURL = "https://login.docker.com"
	Audience  = "https://hub.docker.com"
	ClientID  = "L4v0dmlNBpYUjGGab0C2JtgTgXr1Qz4d"
)

var ErrDeviceLoginTimeout = errors.New("timed out waiting for browser login")

type Client struct {
	HTTP      *http.Client
	UserAgent string
	TenantURL string
	HubURL    string
}

// NewClient returns a Docker Hub OAuth device-flow client with default endpoints and user agent.
func NewClient() *Client {
	return &Client{
		HTTP:      http.DefaultClient,
		UserAgent: fmt.Sprintf("calf:%s:%s-%s", version.Version, runtime.GOOS, runtime.GOARCH),
		TenantURL: TenantURL,
		HubURL:    Audience,
	}
}

// tenantURL returns the configured OAuth tenant base URL, falling back to the package default.
func (c *Client) tenantURL() string {
	if c.TenantURL != "" {
		return c.TenantURL
	}
	return TenantURL
}

// hubURL returns the configured Docker Hub API base URL, falling back to the package default.
func (c *Client) hubURL() string {
	if c.HubURL != "" {
		return c.HubURL
	}
	return Audience
}

type DeviceCode struct {
	DeviceCode      string `json:"device_code"`
	UserCode        string `json:"user_code"`
	VerificationURI string `json:"verification_uri_complete"`
	ExpiresIn       int    `json:"expires_in"`
	Interval        int    `json:"interval"`
}

type tokenResponse struct {
	AccessToken      string  `json:"access_token"`
	RefreshToken     string  `json:"refresh_token"`
	Error            *string `json:"error,omitempty"`
	ErrorDescription string  `json:"error_description,omitempty"`
}

type domainClaims struct {
	Username string `json:"username"`
	Email    string `json:"email"`
}

type accessTokenClaims struct {
	Hub domainClaims `json:"https://hub.docker.com"`
}

type patGenerateResponse struct {
	Data struct {
		Token string `json:"token"`
	} `json:"data"`
}

// StartDeviceLogin requests a device authorization code for browser-based Docker Hub sign-in.
func (c *Client) StartDeviceLogin(ctx context.Context) (DeviceCode, error) {
	data := url.Values{
		"client_id": {ClientID},
		"audience":  {Audience},
		"scope":     {"openid offline_access"},
	}

	resp, err := c.postForm(ctx, c.tenantURL()+"/oauth/device/code", data.Encode())
	if err != nil {
		return DeviceCode{}, err
	}
	defer resp.Body.Close()

	if resp.StatusCode != http.StatusOK {
		return DeviceCode{}, decodeOAuthError(resp)
	}

	var state DeviceCode
	if err := json.NewDecoder(resp.Body).Decode(&state); err != nil {
		return DeviceCode{}, fmt.Errorf("decode device code: %w", err)
	}

	if state.UserCode == "" || state.DeviceCode == "" {
		return DeviceCode{}, errors.New("device login did not return a user code")
	}

	return state, nil
}

// WaitForDeviceToken polls until the user completes browser login or the device code expires.
func (c *Client) WaitForDeviceToken(ctx context.Context, state DeviceCode) (string, error) {
	interval := time.Duration(state.Interval) * time.Second
	if interval <= 0 {
		interval = 5 * time.Second
	}

	timeout := time.NewTimer(time.Duration(state.ExpiresIn) * time.Second)
	defer timeout.Stop()

	ticker := time.NewTimer(interval)
	defer ticker.Stop()

	for {
		select {
		case <-ctx.Done():
			return "", ctx.Err()
		case <-timeout.C:
			return "", ErrDeviceLoginTimeout
		case <-ticker.C:
			token, pending, err := c.pollDeviceToken(ctx, state.DeviceCode)
			if err != nil {
				return "", err
			}
			if pending {
				resetTimer(ticker, interval)
				continue
			}
			return token, nil
		}
	}
}

// pollDeviceToken exchanges a device code for an access token, returning pending when authorization is not finished.
func (c *Client) pollDeviceToken(ctx context.Context, deviceCode string) (string, bool, error) {
	data := url.Values{
		"client_id":   {ClientID},
		"grant_type":  {"urn:ietf:params:oauth:grant-type:device_code"},
		"device_code": {deviceCode},
	}

	resp, err := c.postForm(ctx, c.tenantURL()+"/oauth/token", data.Encode())
	if err != nil {
		return "", false, err
	}
	defer resp.Body.Close()

	var res tokenResponse
	if err := json.NewDecoder(resp.Body).Decode(&res); err != nil {
		return "", false, fmt.Errorf("decode token response: %w", err)
	}

	if res.Error != nil {
		if *res.Error == "authorization_pending" {
			return "", true, nil
		}
		if res.ErrorDescription != "" {
			return "", false, errors.New(res.ErrorDescription)
		}
		return "", false, errors.New(*res.Error)
	}

	if res.AccessToken == "" {
		return "", false, errors.New("missing access token")
	}

	return res.AccessToken, false, nil
}

// GeneratePAT creates a Docker Hub personal access token from a completed OAuth access token.
func (c *Client) GeneratePAT(ctx context.Context, accessToken string) (string, error) {
	req, err := http.NewRequestWithContext(ctx, http.MethodPost, c.hubURL()+"/v2/access-tokens/desktop-generate", nil)
	if err != nil {
		return "", err
	}

	req.Header.Set("Authorization", "Bearer "+accessToken)
	req.Header.Set("Content-Type", "application/json")
	req.Header.Set("User-Agent", c.UserAgent)

	resp, err := c.HTTP.Do(req)
	if err != nil {
		return "", err
	}
	defer resp.Body.Close()

	if resp.StatusCode != http.StatusCreated {
		return "", decodeOAuthError(resp)
	}

	var response patGenerateResponse
	if err := json.NewDecoder(resp.Body).Decode(&response); err != nil {
		return "", fmt.Errorf("decode PAT response: %w", err)
	}

	if response.Data.Token == "" {
		return "", errors.New("missing personal access token")
	}

	return response.Data.Token, nil
}

// UsernameFromAccessToken extracts the Docker Hub username from a JWT access token payload.
func UsernameFromAccessToken(accessToken string) (string, error) {
	parts := strings.Split(accessToken, ".")
	if len(parts) < 2 {
		return "", errors.New("invalid access token")
	}

	payload, err := base64.RawURLEncoding.DecodeString(parts[1])
	if err != nil {
		return "", fmt.Errorf("decode access token claims: %w", err)
	}

	var claims accessTokenClaims
	if err := json.Unmarshal(payload, &claims); err != nil {
		return "", fmt.Errorf("parse access token claims: %w", err)
	}

	if claims.Hub.Username != "" {
		return claims.Hub.Username, nil
	}

	return "", errors.New("username not found in access token")
}

// postForm sends an application/x-www-form-urlencoded POST request.
func (c *Client) postForm(ctx context.Context, reqURL, body string) (*http.Response, error) {
	req, err := http.NewRequestWithContext(ctx, http.MethodPost, reqURL, strings.NewReader(body))
	if err != nil {
		return nil, err
	}

	req.Header.Set("Content-Type", "application/x-www-form-urlencoded")
	req.Header.Set("User-Agent", c.UserAgent)

	return c.HTTP.Do(req)
}

// decodeOAuthError turns a failed OAuth HTTP response into a user-facing error message.
func decodeOAuthError(resp *http.Response) error {
	body, err := io.ReadAll(resp.Body)
	if err != nil {
		return fmt.Errorf("oauth request failed: %s", resp.Status)
	}

	var payload map[string]any
	if err := json.Unmarshal(body, &payload); err == nil {
		if message, ok := payload["error_description"].(string); ok && message != "" {
			return errors.New(message)
		}
		if message, ok := payload["error"].(string); ok && message != "" {
			return errors.New(message)
		}
	}

	return fmt.Errorf("oauth request failed: %s", resp.Status)
}

// resetTimer stops and restarts a timer with a new interval, draining a pending tick when needed.
func resetTimer(t *time.Timer, d time.Duration) {
	if !t.Stop() {
		select {
		case <-t.C:
		default:
		}
	}
	t.Reset(d)
}
