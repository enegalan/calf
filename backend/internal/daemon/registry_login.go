package daemon

import (
	"context"
	"crypto/rand"
	"encoding/hex"
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

	sessionID := newRegistrySessionID()
	flowCtx, cancel := context.WithTimeout(context.Background(), time.Duration(state.ExpiresIn)*time.Second)

	session := &registryLoginSession{
		id:              sessionID,
		status:          "pending",
		userCode:        state.UserCode,
		verificationURL: state.VerificationURI,
		cancel:          cancel,
	}

	s.loginSessions().Store(sessionID, session)
	go s.completeRegistryDeviceLogin(flowCtx, client, session, state)

	if err := browser.OpenURL(state.VerificationURI); err != nil {
		s.Logger.Warn("failed to open browser for docker login", "error", err, "url", state.VerificationURI)
	}

	return RegistryDeviceLoginStart{
		SessionID:       sessionID,
		UserCode:        state.UserCode,
		VerificationURL: state.VerificationURI,
		ExpiresIn:       state.ExpiresIn,
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

func (s *Core) loginSessions() *sync.Map {
	if s.registryLoginSessions == nil {
		s.registryLoginSessions = &sync.Map{}
	}
	return s.registryLoginSessions
}

func (s *Core) completeRegistryDeviceLogin(ctx context.Context, client *dockerhub.Client, session *registryLoginSession, state dockerhub.DeviceCode) {
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
			s.loginSessions().Delete(session.id)
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

	time.AfterFunc(10*time.Minute, func() {
		s.loginSessions().Delete(session.id)
	})
}

func newRegistrySessionID() string {
	var bytes [16]byte
	_, _ = rand.Read(bytes[:])
	return hex.EncodeToString(bytes[:])
}
