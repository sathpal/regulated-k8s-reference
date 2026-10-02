// payments-api: a small payments service built the way a regulated bank needs it to behave.
//
//   - Card numbers (PANs) are never logged or returned in full (PCI DSS requirement 3).
//   - Every request is written to an audit log on stdout as JSON with a request id (requirement 10).
//   - POST /v1/payments is idempotent on the Idempotency-Key header, so a retry never pays twice.
//   - /readyz turns false on SIGTERM before the server stops, so Kubernetes drains traffic first.
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
	"regexp"
	"strconv"
	"sync"
	"sync/atomic"
	"syscall"
	"time"
)

var version = "dev" // set at build time with -ldflags "-X main.version=..."

type Payment struct {
	ID          string `json:"id"`
	AmountMinor int64  `json:"amount_minor"`
	Currency    string `json:"currency"`
	CardMasked  string `json:"card"`
	Status      string `json:"status"`
	CreatedAt   string `json:"created_at"`
}

type paymentRequest struct {
	AmountMinor int64  `json:"amount_minor"`
	Currency    string `json:"currency"`
	CardNumber  string `json:"card_number"`
}

type server struct {
	ready    atomic.Bool
	mu       sync.Mutex
	byKey    map[string]Payment // idempotency key -> payment
	byID     map[string]Payment
	log      *slog.Logger
	failMode bool // FAIL_READINESS=true simulates a bad release in the deployment drills
}

var digits = regexp.MustCompile(`^[0-9]{12,19}$`)

// maskPAN keeps the first six and last four digits, the most PCI DSS allows to be displayed.
func maskPAN(pan string) string {
	if len(pan) < 10 {
		return "****"
	}
	return pan[:6] + "******" + pan[len(pan)-4:]
}

func newID() string { b := make([]byte, 8); _, _ = rand.Read(b); return hex.EncodeToString(b) }

func newServer(logger *slog.Logger) *server {
	return &server{byKey: map[string]Payment{}, byID: map[string]Payment{}, log: logger}
}

func (s *server) routes() http.Handler {
	mux := http.NewServeMux()
	mux.HandleFunc("GET /healthz", func(w http.ResponseWriter, _ *http.Request) { w.Write([]byte("ok\n")) })
	mux.HandleFunc("GET /readyz", func(w http.ResponseWriter, _ *http.Request) {
		if !s.ready.Load() || s.failMode {
			http.Error(w, "not ready", http.StatusServiceUnavailable)
			return
		}
		w.Write([]byte("ready\n"))
	})
	mux.HandleFunc("GET /version", func(w http.ResponseWriter, _ *http.Request) {
		writeJSON(w, http.StatusOK, map[string]string{"service": "payments-api", "version": version})
	})
	mux.HandleFunc("POST /v1/payments", s.createPayment)
	mux.HandleFunc("GET /v1/payments/{id}", s.getPayment)
	return s.audit(mux)
}

func (s *server) createPayment(w http.ResponseWriter, r *http.Request) {
	key := r.Header.Get("Idempotency-Key")
	if key == "" {
		http.Error(w, "Idempotency-Key header is required", http.StatusBadRequest)
		return
	}
	var req paymentRequest
	if err := json.NewDecoder(http.MaxBytesReader(w, r.Body, 4096)).Decode(&req); err != nil {
		http.Error(w, "invalid JSON", http.StatusBadRequest)
		return
	}
	if req.AmountMinor <= 0 || len(req.Currency) != 3 || !digits.MatchString(req.CardNumber) {
		http.Error(w, "amount_minor > 0, a 3-letter currency and a 12-19 digit card_number are required", http.StatusUnprocessableEntity)
		return
	}
	s.mu.Lock()
	defer s.mu.Unlock()
	if p, ok := s.byKey[key]; ok { // a retry: return the original payment, never charge twice
		writeJSON(w, http.StatusOK, p)
		return
	}
	p := Payment{ID: newID(), AmountMinor: req.AmountMinor, Currency: req.Currency,
		CardMasked: maskPAN(req.CardNumber), Status: "authorized", CreatedAt: time.Now().UTC().Format(time.RFC3339)}
	s.byKey[key], s.byID[p.ID] = p, p
	writeJSON(w, http.StatusCreated, p)
}

func (s *server) getPayment(w http.ResponseWriter, r *http.Request) {
	s.mu.Lock()
	p, ok := s.byID[r.PathValue("id")]
	s.mu.Unlock()
	if !ok {
		http.Error(w, "not found", http.StatusNotFound)
		return
	}
	writeJSON(w, http.StatusOK, p)
}

type statusWriter struct {
	http.ResponseWriter
	code int
}

func (sw *statusWriter) WriteHeader(c int) { sw.code = c; sw.ResponseWriter.WriteHeader(c) }

// audit writes one structured line per request: who, what, result, how long. Never the body.
func (s *server) audit(next http.Handler) http.Handler {
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		start, rid := time.Now(), r.Header.Get("X-Request-Id")
		if rid == "" {
			rid = newID()
		}
		w.Header().Set("X-Request-Id", rid)
		sw := &statusWriter{ResponseWriter: w, code: 200}
		next.ServeHTTP(sw, r)
		if r.URL.Path == "/healthz" || r.URL.Path == "/readyz" {
			return
		}
		s.log.Info("audit", "request_id", rid, "method", r.Method, "path", r.URL.Path, "status", sw.code,
			"caller", r.Header.Get("X-Caller"), "duration_ms", time.Since(start).Milliseconds())
	})
}

func writeJSON(w http.ResponseWriter, code int, v any) {
	w.Header().Set("Content-Type", "application/json")
	w.WriteHeader(code)
	_ = json.NewEncoder(w).Encode(v)
}

func main() {
	logger := slog.New(slog.NewJSONHandler(os.Stdout, nil))
	s := newServer(logger)
	s.failMode = os.Getenv("FAIL_READINESS") == "true"
	drain, _ := strconv.Atoi(getenv("DRAIN_SECONDS", "5"))
	srv := &http.Server{Addr: ":" + getenv("PORT", "8080"), Handler: s.routes(),
		ReadHeaderTimeout: 5 * time.Second, ReadTimeout: 10 * time.Second, WriteTimeout: 10 * time.Second}

	go func() {
		if err := srv.ListenAndServe(); err != nil && !errors.Is(err, http.ErrServerClosed) {
			logger.Error("server failed", "err", err)
			os.Exit(1)
		}
	}()
	s.ready.Store(true)
	logger.Info("started", "version", version, "addr", srv.Addr, "uid", os.Getuid())

	stop := make(chan os.Signal, 1)
	signal.Notify(stop, syscall.SIGTERM, syscall.SIGINT)
	<-stop
	// Fail readiness first, wait for endpoints to update, then stop accepting and finish in-flight requests.
	s.ready.Store(false)
	logger.Info("draining", "seconds", drain)
	time.Sleep(time.Duration(drain) * time.Second)
	ctx, cancel := context.WithTimeout(context.Background(), 15*time.Second)
	defer cancel()
	_ = srv.Shutdown(ctx)
	logger.Info("stopped cleanly")
}

func getenv(k, d string) string {
	if v := os.Getenv(k); v != "" {
		return v
	}
	return d
}
