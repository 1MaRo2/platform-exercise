// Command app is a minimal HTTP service used to demonstrate the platform
// baseline: containerization, IaC and CI/CD. It intentionally uses only the
// Go standard library so the image stays tiny and the dependency scan is clean.
package main

import (
	"context"
	"crypto/rand"
	"encoding/hex"
	"encoding/json"
	"errors"
	"log/slog"
	"net/http"
	"os"
	"os/signal"
	"sync/atomic"
	"syscall"
	"time"
)

// version is injected at build time so a deployment can be traced to the exact
// commit SHA that produced it. This makes smoke tests and rollbacks easier to
// reason about in CI/CD and in the running environment.
var version = "dev"

type ctxKey string

const requestIDKey ctxKey = "request_id"

// server holds the dependencies of the HTTP handlers.
type server struct {
	logger *slog.Logger
	ready  atomic.Bool
}

func newServer(logger *slog.Logger) *server {
	s := &server{logger: logger}
	s.ready.Store(true)
	return s
}

// routes wires the handlers and the middleware chain.
func (s *server) routes() http.Handler {
	mux := http.NewServeMux()
	mux.HandleFunc("GET /health", s.handleHealth)
	mux.HandleFunc("GET /ready", s.handleReady)
	mux.HandleFunc("GET /{$}", s.handleRoot)
	return s.requestID(s.accessLog(mux))
}

// handleHealth is the liveness probe: the process is up and serving HTTP.
func (s *server) handleHealth(w http.ResponseWriter, _ *http.Request) {
	writeJSON(w, http.StatusOK, map[string]string{"status": "ok"})
}

// handleReady is the readiness probe: false while shutting down so the
// platform stops routing traffic before the process exits.
func (s *server) handleReady(w http.ResponseWriter, _ *http.Request) {
	if !s.ready.Load() {
		writeJSON(w, http.StatusServiceUnavailable, map[string]string{"status": "shutting_down"})
		return
	}
	writeJSON(w, http.StatusOK, map[string]string{"status": "ready"})
}

// handleRoot returns the build version so a deployment can be verified.
func (s *server) handleRoot(w http.ResponseWriter, _ *http.Request) {
	writeJSON(w, http.StatusOK, map[string]string{
		"service": "platform-exercise",
		"version": version,
		"env":     getenv("APP_ENV", "local"),
	})
}

// requestID propagates X-Request-ID or generates one, for log correlation.
func (s *server) requestID(next http.Handler) http.Handler {
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		id := r.Header.Get("X-Request-ID")
		if id == "" || len(id) > 128 {
			id = newID()
		}
		w.Header().Set("X-Request-ID", id)
		next.ServeHTTP(w, r.WithContext(context.WithValue(r.Context(), requestIDKey, id)))
	})
}

// accessLog emits one structured JSON line per request.
func (s *server) accessLog(next http.Handler) http.Handler {
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		start := time.Now()
		rec := &statusRecorder{ResponseWriter: w, status: http.StatusOK}
		next.ServeHTTP(rec, r)
		id, _ := r.Context().Value(requestIDKey).(string)
		s.logger.Info("request",
			"request_id", id,
			"http.method", r.Method,
			"http.route", r.URL.Path,
			"http.status", rec.status,
			"duration_ms", time.Since(start).Milliseconds(),
		)
	})
}

type statusRecorder struct {
	http.ResponseWriter
	status int
}

func (r *statusRecorder) WriteHeader(code int) {
	r.status = code
	r.ResponseWriter.WriteHeader(code)
}

func writeJSON(w http.ResponseWriter, status int, body any) {
	w.Header().Set("Content-Type", "application/json")
	w.WriteHeader(status)
	_ = json.NewEncoder(w).Encode(body)
}

func newID() string {
	b := make([]byte, 16)
	if _, err := rand.Read(b); err != nil {
		return "unknown"
	}
	return hex.EncodeToString(b)
}

func getenv(key, fallback string) string {
	if v := os.Getenv(key); v != "" {
		return v
	}
	return fallback
}

func main() {
	logger := slog.New(slog.NewJSONHandler(os.Stdout, nil)).With(
		"service", "platform-exercise",
		"version", version,
		"env", getenv("APP_ENV", "local"),
	)
	s := newServer(logger)

	srv := &http.Server{
		Addr:              ":" + getenv("PORT", "8080"),
		Handler:           s.routes(),
		ReadHeaderTimeout: 5 * time.Second,
		ReadTimeout:       10 * time.Second,
		WriteTimeout:      10 * time.Second,
		IdleTimeout:       60 * time.Second,
	}

	ctx, stop := signal.NotifyContext(context.Background(), syscall.SIGINT, syscall.SIGTERM)
	defer stop()

	go func() {
		logger.Info("server starting", "addr", srv.Addr)
		if err := srv.ListenAndServe(); err != nil && !errors.Is(err, http.ErrServerClosed) {
			logger.Error("server failed", "error", err)
			os.Exit(1)
		}
	}()

	<-ctx.Done()
	// We stop advertising readiness before shutdown so the platform drains traffic
	// away from this instance instead of abruptly dropping requests during a deploy.
	s.ready.Store(false)
	logger.Info("shutdown signal received, draining")
	shutdownCtx, cancel := context.WithTimeout(context.Background(), 15*time.Second)
	defer cancel()
	if err := srv.Shutdown(shutdownCtx); err != nil {
		logger.Error("graceful shutdown failed", "error", err)
		os.Exit(1)
	}
	logger.Info("server stopped")
}
