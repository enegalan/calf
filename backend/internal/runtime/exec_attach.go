package runtime

import (
	"context"
	"io"
	"os/exec"
	"sync"

	"github.com/creack/pty"
)

type ExecResize struct {
	Rows uint16
	Cols uint16
}

// attachContainerExec runs command in a PTY, forwarding stdin, stdout, and terminal resize events until the process exits.
func attachContainerExec(ctx context.Context, command *exec.Cmd, stdin io.Reader, onOutput func([]byte), resizeCh <-chan ExecResize) error {
	ptmx, err := pty.Start(command)
	if err != nil {
		return err
	}
	defer ptmx.Close()

	var writeMu sync.Mutex
	setSize := func(size ExecResize) {
		if size.Rows == 0 || size.Cols == 0 {
			return
		}
		writeMu.Lock()
		defer writeMu.Unlock()
		_ = pty.Setsize(ptmx, &pty.Winsize{Rows: size.Rows, Cols: size.Cols})
	}

	execCtx, cancel := context.WithCancel(ctx)
	defer cancel()

	var wg sync.WaitGroup

	wg.Add(1)
	go func() {
		defer wg.Done()
		buffer := make([]byte, 4096)
		for {
			n, readErr := ptmx.Read(buffer)
			if n > 0 {
				chunk := append([]byte(nil), buffer[:n]...)
				onOutput(chunk)
			}
			if readErr != nil {
				cancel()
				return
			}
		}
	}()

	wg.Add(1)
	go func() {
		defer wg.Done()
		_, copyErr := io.Copy(ptmx, stdin)
		if copyErr != nil {
			cancel()
		}
	}()

	wg.Add(1)
	go func() {
		defer wg.Done()
		for {
			select {
			case <-execCtx.Done():
				return
			case size, ok := <-resizeCh:
				if !ok {
					return
				}
				setSize(size)
			}
		}
	}()

	waitErr := command.Wait()
	cancel()
	wg.Wait()

	if ctx.Err() != nil {
		return ctx.Err()
	}

	return waitErr
}
