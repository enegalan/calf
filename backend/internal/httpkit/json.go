package httpkit

import (
	"encoding/json"
	"io"
	"net/http"
)

// JSONDecode reads and unmarshals the request body into payload, closing the body when done.
func JSONDecode(r *http.Request, payload any) error {
	defer r.Body.Close()

	body, err := io.ReadAll(r.Body)
	if err != nil {
		return err
	}

	return json.Unmarshal(body, payload)
}
