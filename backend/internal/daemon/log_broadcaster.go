package daemon

import (
	"context"
	"sync"
	"time"

	"github.com/enegalan/calf/backend/internal/constants"
	"github.com/enegalan/calf/backend/internal/runtime"
)

// logBroadcaster multiplexes one nerdctl log stream per container onto N
// WebSocket subscribers and tears the stream down when the last one leaves.
type logBroadcaster struct {
	mu      sync.Mutex
	streams map[string]*sharedLogStream
}

// newLogBroadcaster creates an empty logBroadcaster ready to multiplex container log streams.
func newLogBroadcaster() *logBroadcaster {
	return &logBroadcaster{
		streams: make(map[string]*sharedLogStream),
	}
}

type sharedLogStream struct {
	containerID string
	subscribers map[chan string]struct{}
	cancel      context.CancelFunc
	stopping    bool
	mu          sync.Mutex
	history     []string
}

// isStopping reports whether the shared stream is being torn down after the last subscriber left.
func (s *sharedLogStream) isStopping() bool {
	s.mu.Lock()
	defer s.mu.Unlock()

	return s.stopping
}

// subscribe registers a log line channel for containerID and starts the nerdctl stream when needed.
func (b *logBroadcaster) subscribe(rt runtime.Runtime, containerID string) (<-chan string, func()) {
	ch := make(chan string, 256)

	b.mu.Lock()
	stream, ok := b.streams[containerID]
	if ok && stream.isStopping() {
		delete(b.streams, containerID)
		ok = false
	}
	if !ok {
		stream = &sharedLogStream{
			containerID: containerID,
			subscribers: make(map[chan string]struct{}),
		}
		b.streams[containerID] = stream
	}
	b.mu.Unlock()

	stream.mu.Lock()
	stream.subscribers[ch] = struct{}{}
	history := append([]string(nil), stream.history...)
	shouldStart := stream.cancel == nil && !stream.stopping
	if shouldStart {
		runCtx, cancel := context.WithCancel(context.Background())
		stream.cancel = cancel
		go b.runStream(runCtx, rt, stream)
	}
	stream.mu.Unlock()

	go func(lines []string) {
		for _, line := range lines {
			trySendLogLine(ch, line)
		}
	}(history)

	unsubscribe := func() {
		b.release(containerID, ch)
	}

	return ch, unsubscribe
}

// release removes a subscriber and cancels the underlying log stream when the last one disconnects.
func (b *logBroadcaster) release(containerID string, ch chan string) {
	b.mu.Lock()
	stream := b.streams[containerID]
	b.mu.Unlock()
	if stream == nil {
		return
	}

	var cancel context.CancelFunc

	stream.mu.Lock()
	delete(stream.subscribers, ch)
	if len(stream.subscribers) == 0 {
		stream.stopping = true
		cancel = stream.cancel
	}
	stream.mu.Unlock()

	if cancel == nil {
		return
	}

	cancel()
}

// runStream tails container logs, replaying history once then following new lines until canceled.
func (b *logBroadcaster) runStream(ctx context.Context, rt runtime.Runtime, stream *sharedLogStream) {
	defer b.cleanupStream(stream.containerID, stream)

	sentHistory := false
	for {
		if ctx.Err() != nil {
			return
		}

		if !stream.hasSubscribers() {
			return
		}

		var err error
		if !sentHistory {
			err = rt.StreamLogs(ctx, stream.containerID, stream.publish)
			sentHistory = true
		} else {
			err = rt.StreamLogsFollow(ctx, stream.containerID, stream.publish)
		}
		_ = err

		if ctx.Err() != nil {
			return
		}

		select {
		case <-ctx.Done():
			return
		case <-time.After(500 * time.Millisecond):
		}
	}
}

// cleanupStream removes a finished stream from the broadcaster map and resets its lifecycle state.
func (b *logBroadcaster) cleanupStream(containerID string, stream *sharedLogStream) {
	stream.mu.Lock()
	stream.cancel = nil
	stream.stopping = false
	stream.mu.Unlock()

	b.mu.Lock()
	if b.streams[containerID] == stream {
		delete(b.streams, containerID)
	}
	b.mu.Unlock()
}

// hasSubscribers reports whether the shared stream still has active WebSocket subscribers.
func (s *sharedLogStream) hasSubscribers() bool {
	s.mu.Lock()
	defer s.mu.Unlock()

	return len(s.subscribers) > 0
}

// publish appends a log line to the ring buffer and fans it out to all current subscribers.
func (s *sharedLogStream) publish(line string) {
	s.mu.Lock()
	s.history = append(s.history, line)
	if len(s.history) > constants.LogTailLineCount {
		s.history = s.history[len(s.history)-constants.LogTailLineCount:]
	}

	subscribers := make([]chan string, 0, len(s.subscribers))
	for ch := range s.subscribers {
		subscribers = append(subscribers, ch)
	}
	s.mu.Unlock()

	for _, ch := range subscribers {
		trySendLogLine(ch, line)
	}
}

// trySendLogLine sends line to ch without blocking when the subscriber buffer is full.
func trySendLogLine(ch chan string, line string) {
	select {
	case ch <- line:
	default:
	}
}
