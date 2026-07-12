package runtime

import (
	"bytes"
	"encoding/json"
	"fmt"
)

// decodeInspectDocuments parses nerdctl/docker inspect output as a JSON array or NDJSON stream.
func decodeInspectDocuments[T any](output []byte) ([]T, error) {
	output = bytes.TrimSpace(output)
	if len(output) == 0 {
		return nil, nil
	}

	var array []T
	if err := json.Unmarshal(output, &array); err == nil {
		return array, nil
	}

	results := make([]T, 0)
	remaining := output
	for len(bytes.TrimSpace(remaining)) > 0 {
		remaining = bytes.TrimSpace(remaining)
		start := bytes.IndexAny(remaining, "{[")
		if start < 0 {
			break
		}
		if start > 0 {
			remaining = remaining[start:]
		}

		decoder := json.NewDecoder(bytes.NewReader(remaining))
		var value json.RawMessage
		if err := decoder.Decode(&value); err != nil {
			break
		}

		offset := int(decoder.InputOffset())
		if offset <= 0 || offset > len(remaining) {
			break
		}
		remaining = remaining[offset:]

		var items []T
		if err := json.Unmarshal(value, &items); err == nil {
			results = append(results, items...)
			continue
		}

		var item T
		if err := json.Unmarshal(value, &item); err != nil {
			return nil, fmt.Errorf("decode inspect document: %w", err)
		}

		results = append(results, item)
	}

	if len(results) == 0 {
		return nil, fmt.Errorf("no inspect documents decoded")
	}

	return results, nil
}
