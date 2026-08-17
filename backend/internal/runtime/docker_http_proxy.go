package runtime

import (
	"bytes"
	"fmt"
	"io"
	"net"
	"strconv"
	"strings"
	"time"

	"github.com/enegalan/calf/backend/internal/constants"
)

const (
	dockerAPIMaxHTTPHeader = 1 << 20
	// DockerAPIHeaderReadTimeout bounds waiting for the first HTTP request on a
	// Docker API unix connection before dialing the guest vsock.
	DockerAPIHeaderReadTimeout = 30 * time.Second
)

// ProxyDockerAPI forwards one Docker API connection after reading the request head.
func ProxyDockerAPI(client, server net.Conn) {
	head, rest, upgrade, err := ReadDockerAPIRequestHead(client)
	if err != nil {
		return
	}
	ProxyDockerAPIWithHead(client, server, head, rest, upgrade)
}

// ProxyDockerAPIWithHead forwards an already-read Docker API request.
//
// Plain HTTP: clamp API version, force Connection: close, forward one request
// body, then copy only engine→client. Keeping a client→engine copy open for
// keep-alive follow-ups wedges virtio-vsock when dockerd ignores close (buildx
// / compose fan-out then sees EOF on later calls).
//
// Hijacked streams (Upgrade: tcp) keep both directions open without CloseWrite
// on the engine side — vsock treats half-close as full teardown, which drops
// `docker run`/`exec` stdout.
func ProxyDockerAPIWithHead(client, server net.Conn, head, rest []byte, upgrade bool) {
	if upgrade {
		proxyDockerAPIUpgrade(client, server, head, rest)
		return
	}

	head = ClampDockerAPIVersion(head, constants.GuestDockerAPIVersion)
	head = forceHTTPConnectionClose(head)
	if _, err := server.Write(head); err != nil {
		return
	}
	if err := forwardDockerAPIRequestBody(server, client, rest, head); err != nil {
		return
	}
	_, _ = io.Copy(client, server)
	_ = client.Close()
	_ = server.Close()
}

// proxyDockerAPIUpgrade bidirectionally proxies a Docker API hijacked stream.
func proxyDockerAPIUpgrade(client, server net.Conn, head, rest []byte) {
	if _, err := server.Write(head); err != nil {
		return
	}
	clientReader := io.Reader(client)
	if len(rest) > 0 {
		clientReader = io.MultiReader(bytes.NewReader(rest), client)
	}

	done := make(chan struct{}, 2)
	go func() {
		_, _ = io.Copy(server, clientReader)
		done <- struct{}{}
	}()
	go func() {
		_, _ = io.Copy(client, server)
		done <- struct{}{}
	}()
	<-done
	<-done
	_ = client.Close()
	_ = server.Close()
}

// forwardDockerAPIRequestBody writes the remainder of a plain HTTP request body
// to the engine. Known Content-Length is copied exactly; chunked/unknown bodies
// fall back to draining rest then stopping (Docker API requests almost always
// set Content-Length).
func forwardDockerAPIRequestBody(server net.Conn, client net.Conn, rest []byte, head []byte) error {
	length, ok := httpRequestContentLength(head)
	if !ok {
		if len(rest) == 0 {
			return nil
		}
		_, err := server.Write(rest)
		return err
	}
	if length <= 0 {
		return nil
	}
	reader := io.Reader(client)
	if len(rest) > 0 {
		reader = io.MultiReader(bytes.NewReader(rest), client)
	}
	_, err := io.CopyN(server, reader, length)
	return err
}

// httpRequestContentLength parses Content-Length from an HTTP request head.
// ok is false when Transfer-Encoding is chunked or the length is missing/invalid
// while a body may still follow.
func httpRequestContentLength(head []byte) (int64, bool) {
	lower := bytes.ToLower(head)
	if bytes.Contains(lower, []byte("\r\ntransfer-encoding: chunked")) {
		return 0, false
	}
	for _, line := range bytes.Split(head, []byte("\r\n")) {
		lowerLine := bytes.ToLower(line)
		if !bytes.HasPrefix(lowerLine, []byte("content-length:")) {
			continue
		}
		value := strings.TrimSpace(string(line[len("content-length:"):]))
		n, err := strconv.ParseInt(value, 10, 64)
		if err != nil || n < 0 {
			return 0, false
		}
		return n, true
	}
	return 0, true
}

// ClampDockerAPIVersion rewrites /v1.N/ in the request line when N is newer than
// maxVersion so host Docker CLIs newer than the guest engine still work.
func ClampDockerAPIVersion(head []byte, maxVersion string) []byte {
	if len(head) == 0 || maxVersion == "" {
		return head
	}
	trimmed := bytes.TrimSuffix(head, []byte("\r\n\r\n"))
	lines := bytes.Split(trimmed, []byte("\r\n"))
	if len(lines) == 0 {
		return head
	}
	parts := bytes.SplitN(lines[0], []byte(" "), 3)
	if len(parts) < 2 {
		return head
	}
	path := parts[1]
	const prefix = "/v"
	idx := bytes.Index(path, []byte(prefix))
	if idx < 0 {
		return head
	}
	verStart := idx + len(prefix)
	verEnd := verStart
	for verEnd < len(path) {
		c := path[verEnd]
		if (c >= '0' && c <= '9') || c == '.' {
			verEnd++
			continue
		}
		break
	}
	if verEnd <= verStart {
		return head
	}
	clientVersion := string(path[verStart:verEnd])
	if !dockerAPIVersionNewer(clientVersion, maxVersion) {
		return head
	}
	newPath := make([]byte, 0, verStart+len(maxVersion)+(len(path)-verEnd))
	newPath = append(newPath, path[:verStart]...)
	newPath = append(newPath, maxVersion...)
	newPath = append(newPath, path[verEnd:]...)
	parts[1] = newPath
	lines[0] = bytes.Join(parts, []byte(" "))
	return append(bytes.Join(lines, []byte("\r\n")), []byte("\r\n\r\n")...)
}

// dockerAPIVersionNewer reports whether a is a higher Docker API version than b
// (dotted integers, e.g. 1.55 > 1.52).
func dockerAPIVersionNewer(a, b string) bool {
	aParts := strings.Split(a, ".")
	bParts := strings.Split(b, ".")
	n := len(aParts)
	if len(bParts) > n {
		n = len(bParts)
	}
	for i := 0; i < n; i++ {
		var av, bv int
		if i < len(aParts) {
			av, _ = strconv.Atoi(aParts[i])
		}
		if i < len(bParts) {
			bv, _ = strconv.Atoi(bParts[i])
		}
		if av != bv {
			return av > bv
		}
	}
	return false
}

// ReadDockerAPIRequestHead reads until the end of HTTP headers (or EOF).
func ReadDockerAPIRequestHead(r io.Reader) (head, rest []byte, upgrade bool, err error) {
	buf := make([]byte, 0, 4096)
	tmp := make([]byte, 2048)
	for {
		if len(buf) > dockerAPIMaxHTTPHeader {
			return nil, nil, false, fmt.Errorf("docker API headers exceed %d bytes", dockerAPIMaxHTTPHeader)
		}
		n, readErr := r.Read(tmp)
		if n > 0 {
			buf = append(buf, tmp[:n]...)
			if idx := bytes.Index(buf, []byte("\r\n\r\n")); idx >= 0 {
				head = buf[:idx+4]
				rest = buf[idx+4:]
				return head, rest, httpRequestHeadIsUpgrade(head), nil
			}
		}
		if readErr != nil {
			if len(buf) == 0 {
				return nil, nil, false, readErr
			}
			if readErr == io.EOF {
				return buf, nil, httpRequestHeadIsUpgrade(buf), nil
			}
			return nil, nil, false, readErr
		}
	}
}

// httpRequestHeadIsUpgrade reports a Docker API hijack (attach/exec/raw stream).
func httpRequestHeadIsUpgrade(head []byte) bool {
	return bytes.Contains(bytes.ToLower(head), []byte("\r\nupgrade:"))
}

// forceHTTPConnectionClose strips Connection headers and adds Connection: close.
func forceHTTPConnectionClose(head []byte) []byte {
	if len(head) == 0 {
		return head
	}
	trimmed := bytes.TrimSuffix(head, []byte("\r\n\r\n"))
	lines := bytes.Split(trimmed, []byte("\r\n"))
	out := make([][]byte, 0, len(lines)+1)
	for i, line := range lines {
		if i == 0 {
			out = append(out, line)
			continue
		}
		lower := bytes.ToLower(line)
		if bytes.HasPrefix(lower, []byte("connection:")) {
			continue
		}
		out = append(out, line)
	}
	out = append(out, []byte("Connection: close"))
	return append(bytes.Join(out, []byte("\r\n")), []byte("\r\n\r\n")...)
}
