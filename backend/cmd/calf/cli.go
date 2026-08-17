package main

import (
	"context"
	"fmt"
	"io"
	"net/http"
	"os"

	"github.com/enegalan/calf/backend/internal/config"
	"github.com/enegalan/calf/backend/internal/constants"
	"github.com/enegalan/calf/backend/internal/daemon"
)

// runHostCLI handles calf-daemon subcommands that talk to a running daemon over HTTP.
func runHostCLI(args []string) int {
	if len(args) == 0 {
		fmt.Fprintln(os.Stderr, "usage: calf-daemon status|start|stop|restart|logs|diagnose [path]")
		return 2
	}
	os.Setenv("PATH", ensurePath())
	cfg, err := config.Load()
	if err != nil {
		fmt.Fprintf(os.Stderr, "load config: %v\n", err)
		return 1
	}
	base := "http://" + cfg.ListenAddr
	ctx, cancel := context.WithTimeout(context.Background(), constants.DockerCLITimeout)
	defer cancel()

	switch args[0] {
	case "status":
		return cliStatus(ctx, base)
	case "start":
		return cliPost(ctx, base+"/v1/runtime/start")
	case "stop":
		return cliPost(ctx, base+"/v1/runtime/stop")
	case "restart":
		if code := cliPost(ctx, base+"/v1/runtime/stop"); code != 0 {
			return code
		}
		return cliPost(ctx, base+"/v1/runtime/start")
	case "logs":
		return cliLogs()
	case "diagnose":
		out := ""
		if len(args) > 1 {
			out = args[1]
		}
		return cliDiagnose(out)
	case "helper":
		return runPrivilegedHelper()
	default:
		fmt.Fprintf(os.Stderr, "unknown command %q\n", args[0])
		return 2
	}
}

// cliStatus prints GET /v1/status as JSON, or a stopped message when the daemon is down.
func cliStatus(ctx context.Context, base string) int {
	req, err := http.NewRequestWithContext(ctx, http.MethodGet, base+"/v1/status", nil)
	if err != nil {
		fmt.Fprintf(os.Stderr, "status request: %v\n", err)
		return 1
	}
	resp, err := http.DefaultClient.Do(req)
	if err != nil {
		fmt.Println(`{"daemon":"stopped","error":"daemon is not running"}`)
		return 1
	}
	defer resp.Body.Close()
	body, err := io.ReadAll(io.LimitReader(resp.Body, 1<<20))
	if err != nil {
		fmt.Fprintf(os.Stderr, "read status: %v\n", err)
		return 1
	}
	os.Stdout.Write(body)
	if len(body) > 0 && body[len(body)-1] != '\n' {
		fmt.Println()
	}
	if resp.StatusCode >= 300 {
		return 1
	}
	return 0
}

// cliPost sends an empty POST to url and prints the response body.
func cliPost(ctx context.Context, url string) int {
	req, err := http.NewRequestWithContext(ctx, http.MethodPost, url, nil)
	if err != nil {
		fmt.Fprintf(os.Stderr, "request: %v\n", err)
		return 1
	}
	resp, err := http.DefaultClient.Do(req)
	if err != nil {
		fmt.Fprintf(os.Stderr, "daemon is not running: %v\n", err)
		return 1
	}
	defer resp.Body.Close()
	body, _ := io.ReadAll(io.LimitReader(resp.Body, 1<<20))
	if len(body) > 0 {
		os.Stdout.Write(body)
		if body[len(body)-1] != '\n' {
			fmt.Println()
		}
	}
	if resp.StatusCode >= 300 {
		return 1
	}
	return 0
}

// cliLogs prints the daemon log file.
func cliLogs() int {
	path, err := config.LogFilePath()
	if err != nil {
		fmt.Fprintf(os.Stderr, "log path: %v\n", err)
		return 1
	}
	data, err := os.ReadFile(path)
	if err != nil {
		fmt.Fprintf(os.Stderr, "read logs: %v\n", err)
		return 1
	}
	os.Stdout.Write(data)
	return 0
}

// cliDiagnose writes a local diagnostics zip and prints its path.
func cliDiagnose(out string) int {
	path, err := daemon.WriteDiagnosticsBundle(out)
	if err != nil {
		fmt.Fprintf(os.Stderr, "diagnose: %v\n", err)
		return 1
	}
	fmt.Println(path)
	return 0
}
