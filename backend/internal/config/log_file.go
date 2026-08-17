package config

import (
	"io"
	"os"
	"strings"
	"sync"

	"github.com/enegalan/calf/backend/internal/constants"
)

// rotatingFile appends to a log file and rotates it when it exceeds DaemonLogMaxBytes.
type rotatingFile struct {
	mu   sync.Mutex
	f    *os.File
	path string
}

// newRotatingFile opens path for append, rotating first when the file is already over the size cap.
func newRotatingFile(path string) (*rotatingFile, error) {
	if err := rotateIfNeeded(path); err != nil {
		return nil, err
	}
	f, err := os.OpenFile(path, os.O_CREATE|os.O_WRONLY|os.O_APPEND, 0o644)
	if err != nil {
		return nil, err
	}
	return &rotatingFile{f: f, path: path}, nil
}

// Write appends p to the log file, rotating when the next write would exceed the size cap.
func (w *rotatingFile) Write(p []byte) (int, error) {
	w.mu.Lock()
	defer w.mu.Unlock()
	if w.f == nil {
		return 0, os.ErrClosed
	}
	if st, err := w.f.Stat(); err == nil && st.Size()+int64(len(p)) > constants.DaemonLogMaxBytes {
		if err := w.rotateLocked(); err != nil {
			return 0, err
		}
	}
	return w.f.Write(p)
}

// Reopen closes the current file and opens path again (after delete or factory reset).
func (w *rotatingFile) Reopen() error {
	w.mu.Lock()
	defer w.mu.Unlock()
	if w.f != nil {
		_ = w.f.Close()
		w.f = nil
	}
	if err := rotateIfNeeded(w.path); err != nil {
		return err
	}
	f, err := os.OpenFile(w.path, os.O_CREATE|os.O_WRONLY|os.O_APPEND, 0o644)
	if err != nil {
		return err
	}
	w.f = f
	return nil
}

// Close closes the underlying log file.
func (w *rotatingFile) Close() error {
	w.mu.Lock()
	defer w.mu.Unlock()
	if w.f == nil {
		return nil
	}
	err := w.f.Close()
	w.f = nil
	return err
}

// Clear truncates the active log and removes the rotated backup, then reopens the file.
func (w *rotatingFile) Clear() error {
	w.mu.Lock()
	defer w.mu.Unlock()
	if w.f != nil {
		if err := w.f.Close(); err != nil {
			return err
		}
		w.f = nil
	}
	if err := os.Remove(w.path); err != nil && !os.IsNotExist(err) {
		return err
	}
	if err := os.Remove(w.path + ".1"); err != nil && !os.IsNotExist(err) {
		return err
	}
	f, err := os.OpenFile(w.path, os.O_CREATE|os.O_WRONLY|os.O_APPEND, 0o644)
	if err != nil {
		return err
	}
	w.f = f
	return nil
}

// rotateLocked replaces the current file with a fresh one. Caller must hold w.mu.
func (w *rotatingFile) rotateLocked() error {
	if err := w.f.Close(); err != nil {
		return err
	}
	w.f = nil
	if err := rotateIfNeeded(w.path); err != nil {
		return err
	}
	f, err := os.OpenFile(w.path, os.O_CREATE|os.O_WRONLY|os.O_APPEND, 0o644)
	if err != nil {
		return err
	}
	w.f = f
	return nil
}

// rotateIfNeeded renames path to path.1 when path is already over the size cap.
func rotateIfNeeded(path string) error {
	st, err := os.Stat(path)
	if err != nil {
		if os.IsNotExist(err) {
			return nil
		}
		return err
	}
	if st.Size() < constants.DaemonLogMaxBytes {
		return nil
	}
	backup := path + ".1"
	_ = os.Remove(backup)
	return os.Rename(path, backup)
}

// ReadLogTail returns the last maxBytes of the daemon log file and the file path.
func ReadLogTail(maxBytes int64) (string, string, error) {
	if maxBytes <= 0 {
		maxBytes = constants.DaemonLogTailBytes
	}

	path, err := LogFilePath()
	if err != nil {
		return "", "", err
	}

	f, err := os.Open(path)
	if err != nil {
		if os.IsNotExist(err) {
			return "", path, nil
		}
		return "", path, err
	}
	defer f.Close()

	st, err := f.Stat()
	if err != nil {
		return "", path, err
	}

	start := st.Size() - maxBytes
	if start < 0 {
		start = 0
	}
	if start > 0 {
		if _, err := f.Seek(start, io.SeekStart); err != nil {
			return "", path, err
		}
	}

	data, err := io.ReadAll(f)
	if err != nil {
		return "", path, err
	}

	text := string(data)
	if start > 0 {
		if i := strings.IndexByte(text, '\n'); i >= 0 {
			text = text[i+1:]
		}
	}
	return text, path, nil
}
