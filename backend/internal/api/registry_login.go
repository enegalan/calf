package api

import (
	"context"
	"crypto/rand"
	"encoding/hex"
	"net/http"
	"strings"
	"sync"
	"time"

	"github.com/enegalan/calf/backend/internal/browser"
	"github.com/enegalan/calf/backend/internal/oauth/dockerhub"
)

type registryLoginSession struct {
	mu              sync.RWMutex
	id              string
	status          string
	userCode        string
	verificationURL string
	username        string
	err             string
	cancel          context.CancelFunc
}

type registryDeviceLoginStartResponse struct {
	SessionID       string `json:"session_id"`
	UserCode        string `json:"user_code"`
	VerificationURL string `json:"verification_url"`
	ExpiresIn       int    `json:"expires_in"`
}

type registryDeviceLoginStatusResponse struct {
	Status   string `json:"status"`
	Username string `json:"username,omitempty"`
	Error    string `json:"error,omitempty"`
}

func (s *Server) registryLoginSessions() *sync.Map {
	if s.registrySessions == nil {
		s.registrySessions = &sync.Map{}
	}
	return s.registrySessions
}

func (s *Server) handleRegistryLogin(w http.ResponseWriter, r *http.Request) {
	if r.Method == http.MethodOptions {
		w.WriteHeader(http.StatusNoContent)
		return
	}

	path := strings.TrimPrefix(r.URL.Path, "/v1/registry/login")
	path = strings.Trim(path, "/")

	if path == "" {
		if r.Method != http.MethodPost {
			methodNotAllowed(w, r)
			return
		}
		s.startRegistryDeviceLogin(w, r)
		return
	}

	if r.Method != http.MethodGet {
		methodNotAllowed(w, r)
		return
	}

	s.getRegistryDeviceLoginStatus(w, r, path)
}

func (s *Server) startRegistryDeviceLogin(w http.ResponseWriter, r *http.Request) {
	client := dockerhub.NewClient()
	state, err := client.StartDeviceLogin(r.Context())
	if err != nil {
		writeError(w, http.StatusBadGateway, err.Error())
		return
	}

	sessionID := newRegistrySessionID()
	ctx, cancel := context.WithTimeout(context.Background(), time.Duration(state.ExpiresIn)*time.Second)

	session := &registryLoginSession{
		id:              sessionID,
		status:          "pending",
		userCode:        state.UserCode,
		verificationURL: state.VerificationURI,
		cancel:          cancel,
	}

	s.registryLoginSessions().Store(sessionID, session)
	go s.completeRegistryDeviceLogin(ctx, client, session, state)

	if err := browser.OpenURL(state.VerificationURI); err != nil {
		s.logger.Warn("failed to open browser for docker login", "error", err, "url", state.VerificationURI)
	}

	writeJSON(w, http.StatusOK, registryDeviceLoginStartResponse{
		SessionID:       sessionID,
		UserCode:        state.UserCode,
		VerificationURL: state.VerificationURI,
		ExpiresIn:       state.ExpiresIn,
	})
}

func (s *Server) getRegistryDeviceLoginStatus(w http.ResponseWriter, r *http.Request, sessionID string) {
	value, ok := s.registryLoginSessions().Load(sessionID)
	if !ok {
		writeError(w, http.StatusNotFound, "login session not found")
		return
	}

	session := value.(*registryLoginSession)
	session.mu.RLock()
	defer session.mu.RUnlock()

	writeJSON(w, http.StatusOK, registryDeviceLoginStatusResponse{
		Status:   session.status,
		Username: session.username,
		Error:    session.err,
	})
}

func (s *Server) completeRegistryDeviceLogin(ctx context.Context, client *dockerhub.Client, session *registryLoginSession, state dockerhub.DeviceCode) {
	defer session.cancel()

	setFailed := func(message string) {
		session.mu.Lock()
		session.status = "failed"
		session.err = message
		session.mu.Unlock()
	}

	accessToken, err := client.WaitForDeviceToken(ctx, state)
	if err != nil {
		status := "failed"
		if err == context.DeadlineExceeded || err == dockerhub.ErrDeviceLoginTimeout {
			status = "expired"
		}
		session.mu.Lock()
		session.status = status
		session.err = err.Error()
		session.mu.Unlock()
		time.AfterFunc(10*time.Minute, func() {
			s.registryLoginSessions().Delete(session.id)
		})
		return
	}

	username, err := dockerhub.UsernameFromAccessToken(accessToken)
	if err != nil {
		setFailed(err.Error())
		return
	}

	pat, err := client.GeneratePAT(ctx, accessToken)
	if err != nil {
		setFailed(err.Error())
		return
	}

	session.mu.Lock()
	session.status = "saving"
	session.username = username
	session.mu.Unlock()

	if err := s.ensureRuntimeRunning(ctx); err != nil {
		setFailed(err.Error())
		return
	}

	if err := s.runtime.RegistryLogin(ctx, "", username, pat); err != nil {
		setFailed(err.Error())
		return
	}

	session.mu.Lock()
	session.status = "complete"
	session.username = username
	session.mu.Unlock()

	time.AfterFunc(10*time.Minute, func() {
		s.registryLoginSessions().Delete(session.id)
	})
}

func newRegistrySessionID() string {
	var bytes [16]byte
	_, _ = rand.Read(bytes[:])
	return hex.EncodeToString(bytes[:])
}
