package httpkit

import (
	"encoding/json"
	"io"
	"net/http"
)

// maxJSONBodyBytes caps request bodies decoded via JSONDecode, so a client cannot exhaust
// memory by sending an unbounded body to a JSON endpoint.
const maxJSONBodyBytes = 4 * 1024 * 1024

// JSONDecode reads and unmarshals the request body into payload, closing the body when done.
func JSONDecode(r *http.Request, payload any) error {
	defer r.Body.Close()

	r.Body = http.MaxBytesReader(nil, r.Body, maxJSONBodyBytes)

	body, err := io.ReadAll(r.Body)
	if err != nil {
		return err
	}

	return json.Unmarshal(body, payload)
}

// JSONDecodeOrFail decodes the request body into dest, writing a 400 "invalid json body" response
// and reporting false on failure so the caller can return immediately without leaking parse details.
func JSONDecodeOrFail(w http.ResponseWriter, r *http.Request, dest any) bool {
	if err := JSONDecode(r, dest); err != nil {
		WriteError(w, http.StatusBadRequest, "invalid json body")
		return false
	}

	return true
}
