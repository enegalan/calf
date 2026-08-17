package main

import (
	"encoding/json"
	"fmt"
	"io"
	"net"
	"os"
	"strconv"
	"sync"
)

const privilegedHelperSock = "/var/run/calf-helper.sock"

type helperRequest struct {
	Op     string `json:"op"`
	Port   int    `json:"port"`
	Target string `json:"target"`
}

// runPrivilegedHelper listens on /var/run/calf-helper.sock and forwards privileged TCP ports.
// It must run as root (launchd / sudo). Protocol: one JSON object per connection.
func runPrivilegedHelper() int {
	if os.Geteuid() != 0 {
		fmt.Fprintln(os.Stderr, "helper must run as root")
		return 1
	}
	_ = os.Remove(privilegedHelperSock)
	ln, err := net.Listen("unix", privilegedHelperSock)
	if err != nil {
		fmt.Fprintf(os.Stderr, "listen %s: %v\n", privilegedHelperSock, err)
		return 1
	}
	defer ln.Close()
	_ = os.Chmod(privilegedHelperSock, 0o666)

	var mu sync.Mutex
	listeners := map[int]net.Listener{}

	for {
		conn, err := ln.Accept()
		if err != nil {
			return 1
		}
		go func(c net.Conn) {
			defer c.Close()
			dec := json.NewDecoder(io.LimitReader(c, 4096))
			var req helperRequest
			if err := dec.Decode(&req); err != nil {
				_, _ = c.Write([]byte(`{"error":"invalid json"}`))
				return
			}
			if req.Op != "tcp" || req.Port < 1 || req.Port > 1023 || req.Target == "" {
				_, _ = c.Write([]byte(`{"error":"invalid request"}`))
				return
			}
			mu.Lock()
			if existing, ok := listeners[req.Port]; ok {
				_ = existing.Close()
				delete(listeners, req.Port)
			}
			pln, listenErr := net.Listen("tcp", ":"+strconv.Itoa(req.Port))
			if listenErr != nil {
				mu.Unlock()
				_, _ = c.Write([]byte(`{"error":"` + listenErr.Error() + `"}`))
				return
			}
			listeners[req.Port] = pln
			mu.Unlock()
			go splicePrivileged(pln, req.Target)
			_, _ = c.Write([]byte(`{"ok":true}`))
		}(conn)
	}
}

// splicePrivileged accepts connections on ln and forwards each to target host:port.
func splicePrivileged(ln net.Listener, target string) {
	defer ln.Close()
	for {
		client, err := ln.Accept()
		if err != nil {
			return
		}
		go func(c net.Conn) {
			defer c.Close()
			remote, err := net.Dial("tcp", target)
			if err != nil {
				return
			}
			defer remote.Close()
			done := make(chan struct{}, 2)
			go func() { _, _ = io.Copy(remote, c); done <- struct{}{} }()
			go func() { _, _ = io.Copy(c, remote); done <- struct{}{} }()
			<-done
		}(client)
	}
}
