package runtime

import (
	"bufio"
	"bytes"
	"context"
	"encoding/json"
	"fmt"
	"io"
	"os/exec"
	"strings"
)

type nerdctlLine struct {
	ID         string `json:"ID"`
	Names      string `json:"Names"`
	Image      string `json:"Image"`
	State      string `json:"State"`
	Status     string `json:"Status"`
	CreatedAt  string `json:"CreatedAt"`
	Repository string `json:"Repository"`
	Tag        string `json:"Tag"`
	Size       string `json:"Size"`
}

type commandRunner func(ctx context.Context, command string, args ...string) ([]byte, error)

func listContainers(ctx context.Context, run commandRunner) ([]Container, error) {
	output, err := run(ctx, "nerdctl", "ps", "-a", "--format", "{{json .}}")
	if err != nil {
		return nil, err
	}

	return ParseContainerLines(output)
}

func listImages(ctx context.Context, run commandRunner) ([]Image, error) {
	output, err := run(ctx, "nerdctl", "images", "--format", "{{json .}}")
	if err != nil {
		return nil, err
	}

	return ParseImageLines(output)
}

func ParseContainerLines(output []byte) ([]Container, error) {
	containers := make([]Container, 0)
	scanner := bufio.NewScanner(bytes.NewReader(output))

	for scanner.Scan() {
		line := strings.TrimSpace(scanner.Text())
		if line == "" {
			continue
		}

		var row nerdctlLine
		if err := json.Unmarshal([]byte(line), &row); err != nil {
			return nil, fmt.Errorf("parse container line: %w", err)
		}

		containers = append(containers, Container{
			ID:      row.ID,
			Name:    row.Names,
			Image:   row.Image,
			State:   row.State,
			Status:  row.Status,
			Created: row.CreatedAt,
		})
	}

	if err := scanner.Err(); err != nil {
		return nil, err
	}

	return containers, nil
}

func ParseImageLines(output []byte) ([]Image, error) {
	images := make([]Image, 0)
	scanner := bufio.NewScanner(bytes.NewReader(output))

	for scanner.Scan() {
		line := strings.TrimSpace(scanner.Text())
		if line == "" {
			continue
		}

		var row nerdctlLine
		if err := json.Unmarshal([]byte(line), &row); err != nil {
			return nil, fmt.Errorf("parse image line: %w", err)
		}

		images = append(images, Image{
			ID:         row.ID,
			Repository: row.Repository,
			Tag:        row.Tag,
			Size:       row.Size,
			Created:    row.CreatedAt,
		})
	}

	if err := scanner.Err(); err != nil {
		return nil, err
	}

	return images, nil
}

func streamLogs(ctx context.Context, run commandRunner, id string, output func(string)) error {
	command := exec.CommandContext(ctx, "sh", "-c", fmt.Sprintf("nerdctl logs -f %q", id))
	stdout, err := command.StdoutPipe()
	if err != nil {
		return err
	}

	stderr, err := command.StderrPipe()
	if err != nil {
		return err
	}

	if err := command.Start(); err != nil {
		return err
	}

	go pipeLines(stdout, output)
	go pipeLines(stderr, output)

	return command.Wait()
}

func pipeLines(reader io.Reader, output func(string)) {
	scanner := bufio.NewScanner(reader)
	for scanner.Scan() {
		output(scanner.Text())
	}
}
