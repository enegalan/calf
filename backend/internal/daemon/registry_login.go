package daemon

import (
	"context"
	"crypto/rand"
	"encoding/hex"
	"sync"
	"time"

	"github.com/enegalan/calf/backend/internal/oauth/dockerhub"
)

// defaultDeviceLoginExpiresInSeconds is used when the device-code response omits (or returns
// a non-positive) expires_in, matching the same fallback applied in the dockerhub client.
const defaultDeviceLoginExpiresInSeconds = 900

// registryLoginSession represents a Docker Hub OAuth device-code login session.
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

// RegistryDeviceLoginStart is returned when a Docker Hub device-login flow begins.
type RegistryDeviceLoginStart struct {
	SessionID       string
	UserCode        string
	VerificationURL string
	ExpiresIn       int
}

// RegistryDeviceLoginStatus is the current progress of a device-login session.
type RegistryDeviceLoginStatus struct {
	Status   string
	Username string
	Error    string
}

// StartRegistryDeviceLogin begins a Docker Hub OAuth device-code flow.
func (s *Core) StartRegistryDeviceLogin(ctx context.Context) (RegistryDeviceLoginStart, error) {
	client := dockerhub.NewClient()
	state, err := client.StartDeviceLogin(ctx)
	if err != nil {
		return RegistryDeviceLoginStart{}, err
	}

	expiresIn := state.ExpiresIn
	if expiresIn <= 0 {
		expiresIn = defaultDeviceLoginExpiresInSeconds
	}

	sessionID := newRegistrySessionID()
	flowCtx, cancel := context.WithTimeout(s.Lifecycle(), time.Duration(expiresIn)*time.Second)

	session := &registryLoginSession{
		id:              sessionID,
		status:          "pending",
		userCode:        state.UserCode,
		verificationURL: state.VerificationURI,
		cancel:          cancel,
	}

	s.loginSessions().Store(sessionID, session)
	go s.completeRegistryDeviceLogin(flowCtx, client, session, state)

	return RegistryDeviceLoginStart{
		SessionID:       sessionID,
		UserCode:        state.UserCode,
		VerificationURL: state.VerificationURI,
		ExpiresIn:       expiresIn,
	}, nil
}

// RegistryDeviceLoginStatus returns the current state of a device-login session.
func (s *Core) RegistryDeviceLoginStatus(sessionID string) (RegistryDeviceLoginStatus, bool) {
	value, ok := s.loginSessions().Load(sessionID)
	if !ok {
		return RegistryDeviceLoginStatus{}, false
	}

	session := value.(*registryLoginSession)
	session.mu.RLock()
	defer session.mu.RUnlock()

	return RegistryDeviceLoginStatus{
		Status:   session.status,
		Username: session.username,
		Error:    session.err,
	}, true
}

// CancelRegistryDeviceLogin cancels a pending Docker Hub device-login session.
// Returns false when no session with that id is currently tracked.
func (s *Core) CancelRegistryDeviceLogin(sessionID string) bool {
	value, ok := s.loginSessions().Load(sessionID)
	if !ok {
		return false
	}

	session := value.(*registryLoginSession)
	session.mu.Lock()
	session.status = "cancelled"
	session.mu.Unlock()

	session.cancel()
	s.loginSessions().Delete(sessionID)
	return true
}

// loginSessions returns the sync.Map of registry login sessions.
func (s *Core) loginSessions() *sync.Map {
	if s.registryLoginSessions == nil {
		s.registryLoginSessions = &sync.Map{}
	}
	return s.registryLoginSessions
}

// completeRegistryDeviceLogin completes a Docker Hub OAuth device-code flow.
func (s *Core) completeRegistryDeviceLogin(ctx context.Context, client *dockerhub.Client, session *registryLoginSession, state dockerhub.DeviceCode) {
	defer session.cancel()

	scheduleCleanup := func() {
		time.AfterFunc(10*time.Minute, func() {
			s.loginSessions().Delete(session.id)
		})
	}

	setFailed := func(message string) {
		session.mu.Lock()
		session.status = "failed"
		session.err = message
		session.mu.Unlock()
		scheduleCleanup()
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
		scheduleCleanup()
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

	if err := s.EnsureRuntimeRunning(ctx); err != nil {
		setFailed(err.Error())
		return
	}

	if err := s.Runtime.RegistryLogin(ctx, "", username, pat); err != nil {
		setFailed(err.Error())
		return
	}

	session.mu.Lock()
	session.status = "complete"
	session.username = username
	session.mu.Unlock()

	scheduleCleanup()
}

// newRegistrySessionID generates a random 16-byte hex string for a registry login session.
func newRegistrySessionID() string {
	var bytes [16]byte
	_, _ = rand.Read(bytes[:])
	return hex.EncodeToString(bytes[:])
}
