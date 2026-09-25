package main

import (
	"encoding/json"
	"io"
	"log/slog"
	"net/http"
	"net/http/httptest"
	"testing"
)

func newTestServer() *server {
	return newServer(slog.New(slog.NewJSONHandler(io.Discard, nil)))
}

func TestEndpoints(t *testing.T) {
	tests := []struct {
		name       string
		path       string
		wantStatus int
		wantKey    string
		wantValue  string
	}{
		{"health returns ok", "/health", http.StatusOK, "status", "ok"},
		{"ready returns ready", "/ready", http.StatusOK, "status", "ready"},
		{"root returns version", "/", http.StatusOK, "version", "dev"},
	}

	h := newTestServer().routes()
	for _, tc := range tests {
		t.Run(tc.name, func(t *testing.T) {
			rec := httptest.NewRecorder()
			h.ServeHTTP(rec, httptest.NewRequest(http.MethodGet, tc.path, nil))

			if rec.Code != tc.wantStatus {
				t.Fatalf("status = %d, want %d", rec.Code, tc.wantStatus)
			}
			if ct := rec.Header().Get("Content-Type"); ct != "application/json" {
				t.Errorf("Content-Type = %q, want application/json", ct)
			}
			var body map[string]string
			if err := json.Unmarshal(rec.Body.Bytes(), &body); err != nil {
				t.Fatalf("invalid JSON body: %v", err)
			}
			if body[tc.wantKey] != tc.wantValue {
				t.Errorf("%s = %q, want %q", tc.wantKey, body[tc.wantKey], tc.wantValue)
			}
		})
	}
}

func TestReadyFailsWhileShuttingDown(t *testing.T) {
	s := newTestServer()
	s.ready.Store(false)
	rec := httptest.NewRecorder()
	s.routes().ServeHTTP(rec, httptest.NewRequest(http.MethodGet, "/ready", nil))
	if rec.Code != http.StatusServiceUnavailable {
		t.Fatalf("status = %d, want 503", rec.Code)
	}
}

func TestRequestIDPropagation(t *testing.T) {
	h := newTestServer().routes()

	req := httptest.NewRequest(http.MethodGet, "/health", nil)
	req.Header.Set("X-Request-ID", "abc-123")
	rec := httptest.NewRecorder()
	h.ServeHTTP(rec, req)
	if got := rec.Header().Get("X-Request-ID"); got != "abc-123" {
		t.Errorf("propagated X-Request-ID = %q, want abc-123", got)
	}

	rec = httptest.NewRecorder()
	h.ServeHTTP(rec, httptest.NewRequest(http.MethodGet, "/health", nil))
	if got := rec.Header().Get("X-Request-ID"); len(got) != 32 {
		t.Errorf("generated X-Request-ID = %q, want 32 hex chars", got)
	}
}

func TestUnknownRouteAndMethod(t *testing.T) {
	h := newTestServer().routes()

	rec := httptest.NewRecorder()
	h.ServeHTTP(rec, httptest.NewRequest(http.MethodGet, "/nope", nil))
	if rec.Code != http.StatusNotFound {
		t.Errorf("unknown route status = %d, want 404", rec.Code)
	}

	rec = httptest.NewRecorder()
	h.ServeHTTP(rec, httptest.NewRequest(http.MethodPost, "/health", nil))
	if rec.Code != http.StatusMethodNotAllowed {
		t.Errorf("POST /health status = %d, want 405", rec.Code)
	}
}
