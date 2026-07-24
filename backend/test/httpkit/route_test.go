package httpkit_test

import (
	"net/http"
	"net/http/httptest"
	"testing"

	"github.com/enegalan/calf/backend/internal/httpkit"
)

func TestServeMethodsDispatchesByMethod(t *testing.T) {
	t.Parallel()

	handler := httpkit.ServeMethods(map[string]func(http.ResponseWriter, *http.Request){
		http.MethodGet: func(w http.ResponseWriter, _ *http.Request) {
			w.WriteHeader(http.StatusOK)
		},
		http.MethodPost: func(w http.ResponseWriter, _ *http.Request) {
			w.WriteHeader(http.StatusCreated)
		},
	})

	getReq := httptest.NewRequest(http.MethodGet, "/v1/test", nil)
	getRec := httptest.NewRecorder()
	handler(getRec, getReq)
	if getRec.Code != http.StatusOK {
		t.Fatalf("GET status = %d, want %d", getRec.Code, http.StatusOK)
	}

	postReq := httptest.NewRequest(http.MethodPost, "/v1/test", nil)
	postRec := httptest.NewRecorder()
	handler(postRec, postReq)
	if postRec.Code != http.StatusCreated {
		t.Fatalf("POST status = %d, want %d", postRec.Code, http.StatusCreated)
	}

	optionsReq := httptest.NewRequest(http.MethodOptions, "/v1/test", nil)
	optionsRec := httptest.NewRecorder()
	handler(optionsRec, optionsReq)
	if optionsRec.Code != http.StatusNoContent {
		t.Fatalf("OPTIONS status = %d, want %d", optionsRec.Code, http.StatusNoContent)
	}

	deleteReq := httptest.NewRequest(http.MethodDelete, "/v1/test", nil)
	deleteRec := httptest.NewRecorder()
	handler(deleteRec, deleteReq)
	if deleteRec.Code != http.StatusMethodNotAllowed {
		t.Fatalf("DELETE status = %d, want %d", deleteRec.Code, http.StatusMethodNotAllowed)
	}
}

func TestServeRoutesMatchesSegmentsAndFallback(t *testing.T) {
	t.Parallel()

	handler := httpkit.ServeRoutes("/v1/items/", "item not found", []httpkit.Route{
		{
			Segments: []string{"logs"},
			Method:   http.MethodGet,
			Handler: func(w http.ResponseWriter, _ *http.Request, parts []string) {
				if parts[0] != "abc" {
					t.Fatalf("id = %q, want abc", parts[0])
				}
				w.WriteHeader(http.StatusTeapot)
			},
		},
	}, map[string]httpkit.PartsHandler{
		http.MethodDelete: func(w http.ResponseWriter, _ *http.Request, parts []string) {
			if parts[0] != "abc" {
				t.Fatalf("id = %q, want abc", parts[0])
			}
			w.WriteHeader(http.StatusNoContent)
		},
	})

	logsReq := httptest.NewRequest(http.MethodGet, "/v1/items/abc/logs", nil)
	logsRec := httptest.NewRecorder()
	handler(logsRec, logsReq)
	if logsRec.Code != http.StatusTeapot {
		t.Fatalf("logs status = %d, want %d", logsRec.Code, http.StatusTeapot)
	}

	deleteReq := httptest.NewRequest(http.MethodDelete, "/v1/items/abc", nil)
	deleteRec := httptest.NewRecorder()
	handler(deleteRec, deleteReq)
	if deleteRec.Code != http.StatusNoContent {
		t.Fatalf("delete status = %d, want %d", deleteRec.Code, http.StatusNoContent)
	}

	missingReq := httptest.NewRequest(http.MethodGet, "/v1/items/", nil)
	missingRec := httptest.NewRecorder()
	handler(missingRec, missingReq)
	if missingRec.Code != http.StatusNotFound {
		t.Fatalf("missing status = %d, want %d", missingRec.Code, http.StatusNotFound)
	}

	unknownReq := httptest.NewRequest(http.MethodGet, "/v1/items/abc/unknown", nil)
	unknownRec := httptest.NewRecorder()
	handler(unknownRec, unknownReq)
	if unknownRec.Code != http.StatusMethodNotAllowed {
		t.Fatalf("unknown status = %d, want %d", unknownRec.Code, http.StatusMethodNotAllowed)
	}
}

func TestMatchSegmentsSupportsWildcard(t *testing.T) {
	t.Parallel()

	if !httpkit.MatchSegments([]string{"schedules", "42"}, []string{"schedules", "*"}) {
		t.Fatal("expected wildcard segment to match")
	}

	if httpkit.MatchSegments([]string{"schedules"}, []string{"schedules", "*"}) {
		t.Fatal("expected different segment lengths not to match")
	}
}

func TestPathPartsExactPrefixReturnsNil(t *testing.T) {
	t.Parallel()

	exact := httptest.NewRequest(http.MethodPost, "/v1/registry/login", nil)
	if parts := httpkit.PathParts(exact, "/v1/registry/login/"); parts != nil {
		t.Fatalf("exact path parts = %v, want nil", parts)
	}

	trailing := httptest.NewRequest(http.MethodPost, "/v1/registry/login/", nil)
	if parts := httpkit.PathParts(trailing, "/v1/registry/login/"); parts != nil {
		t.Fatalf("trailing-slash path parts = %v, want nil", parts)
	}

	session := httptest.NewRequest(http.MethodGet, "/v1/registry/login/abc", nil)
	parts := httpkit.PathParts(session, "/v1/registry/login/")
	if len(parts) != 1 || parts[0] != "abc" {
		t.Fatalf("session path parts = %v, want [abc]", parts)
	}

	unrelated := httptest.NewRequest(http.MethodGet, "/v1/registry", nil)
	if parts := httpkit.PathParts(unrelated, "/v1/registry/login/"); parts != nil {
		t.Fatalf("unrelated path parts = %v, want nil", parts)
	}
}
