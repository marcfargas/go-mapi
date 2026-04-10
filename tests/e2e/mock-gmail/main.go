// E2E-02: stdlib Go mock Gmail API server for Playwright E2E tests.
//
// This program is launched as a child process by the Playwright test
// harness. It binds to 127.0.0.1:<port> (or port 0 for auto-assign),
// prints "LISTENING <url>\n" to stdout so the harness can read the
// resolved URL, and serves a single endpoint:
//
//	POST /drafts
//	  Requires Authorization: Bearer <token> header (any non-empty token).
//	  Parses {"message":{"raw":"..."}} JSON body.
//	  Returns 200 {"id":"mock-draft-id"} on success.
//	  Returns 401 on missing/empty Bearer token.
//	  Returns 400 on malformed JSON body.
//
//	GET /healthz → 200 ok
//	GET /__count → returns the number of successful POST /drafts calls
//	               as JSON {"drafts": N} for test assertions.
//
// Runs until the process is killed (SIGINT, SIGKILL). No TLS — this is
// an internal test fixture, never exposed.

package main

import (
	"encoding/json"
	"flag"
	"fmt"
	"io"
	"log"
	"net"
	"net/http"
	"os"
	"strings"
	"sync/atomic"
)

type draftRequest struct {
	Message struct {
		Raw string `json:"raw"`
	} `json:"message"`
}

func main() {
	port := flag.Int("port", 0, "TCP port to listen on (0 = auto-assign)")
	flag.Parse()

	var draftCount int64

	mux := http.NewServeMux()

	mux.HandleFunc("/drafts", func(w http.ResponseWriter, r *http.Request) {
		if r.Method != http.MethodPost {
			http.Error(w, "method not allowed", http.StatusMethodNotAllowed)
			return
		}
		auth := r.Header.Get("Authorization")
		if !strings.HasPrefix(auth, "Bearer ") || len(auth) <= len("Bearer ") {
			w.Header().Set("Content-Type", "application/json")
			w.WriteHeader(http.StatusUnauthorized)
			_, _ = io.WriteString(w, `{"error":"missing bearer token"}`)
			return
		}
		var req draftRequest
		dec := json.NewDecoder(r.Body)
		if err := dec.Decode(&req); err != nil || req.Message.Raw == "" {
			w.Header().Set("Content-Type", "application/json")
			w.WriteHeader(http.StatusBadRequest)
			_, _ = io.WriteString(w, `{"error":"bad request"}`)
			return
		}
		atomic.AddInt64(&draftCount, 1)
		log.Printf("mock-gmail: POST /drafts (count=%d, raw_len=%d)",
			atomic.LoadInt64(&draftCount), len(req.Message.Raw))
		w.Header().Set("Content-Type", "application/json")
		w.WriteHeader(http.StatusOK)
		_, _ = io.WriteString(w, `{"id":"mock-draft-id"}`)
	})

	mux.HandleFunc("/healthz", func(w http.ResponseWriter, r *http.Request) {
		w.WriteHeader(http.StatusOK)
		_, _ = io.WriteString(w, "ok")
	})

	mux.HandleFunc("/__count", func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Content-Type", "application/json")
		w.WriteHeader(http.StatusOK)
		_, _ = fmt.Fprintf(w, `{"drafts":%d}`, atomic.LoadInt64(&draftCount))
	})

	addr := fmt.Sprintf("127.0.0.1:%d", *port)
	listener, err := net.Listen("tcp", addr)
	if err != nil {
		log.Fatalf("mock-gmail: listen: %v", err)
	}

	// Print the resolved URL to stdout so the Playwright harness can
	// parse it. Flush explicitly so the line is visible immediately.
	url := "http://" + listener.Addr().String()
	fmt.Printf("LISTENING %s\n", url)
	_ = os.Stdout.Sync()
	log.Printf("mock-gmail: serving on %s", url)

	srv := &http.Server{Handler: mux}
	if err := srv.Serve(listener); err != nil && err != http.ErrServerClosed {
		log.Fatalf("mock-gmail: serve: %v", err)
	}
}
