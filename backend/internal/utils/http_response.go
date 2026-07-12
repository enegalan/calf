package utils

import (
	"encoding/json"
	"net/http"
)

// WriteOK writes a 200 JSON response with {"status":"ok"}.
func WriteOK(w http.ResponseWriter) {
	w.Header().Set("Content-Type", "application/json")
	w.WriteHeader(http.StatusOK)
	_ = json.NewEncoder(w).Encode(map[string]string{"status": "ok"})
}
