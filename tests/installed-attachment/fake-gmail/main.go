package main

import (
	"bufio"
	"bytes"
	"context"
	"crypto/rand"
	"crypto/rsa"
	"crypto/sha256"
	"crypto/subtle"
	"crypto/tls"
	"crypto/x509"
	"crypto/x509/pkix"
	"encoding/base64"
	"encoding/hex"
	"encoding/json"
	"encoding/pem"
	"errors"
	"flag"
	"fmt"
	"io"
	"math/big"
	"mime"
	"mime/multipart"
	"net"
	"net/http"
	"net/mail"
	"os"
	"os/signal"
	"path/filepath"
	"sort"
	"strings"
	"sync"
	"syscall"
	"time"
)

const syntheticToken = "synthetic-569-not-a-real-token"

type expected struct {
	RunID       string            `json:"runId"`
	Subject     string            `json:"subject"`
	Recipient   string            `json:"recipient"`
	Attachments map[string]string `json:"attachments"`
}

type attachment struct {
	Name   string `json:"name"`
	Length int    `json:"length"`
	SHA256 string `json:"sha256"`
}

type snapshot struct {
	SchemaVersion int          `json:"schemaVersion"`
	RunID         string       `json:"runId"`
	Final         bool         `json:"final"`
	Requests      int64        `json:"requests"`
	UserInfo      int64        `json:"userInfoRequests"`
	DraftRequests int64        `json:"draftRequests"`
	DraftAttempts int64        `json:"draftAttempts"`
	AcceptedDraft int64        `json:"acceptedDrafts"`
	Rejected      int64        `json:"rejectedRequests"`
	Failed        bool         `json:"failed"`
	Errors        []string     `json:"errors"`
	Drafts        []draftEntry `json:"drafts"`
	StartedAt     time.Time    `json:"startedAt"`
	FinalizedAt   time.Time    `json:"finalizedAt,omitempty"`
}

type draftEntry struct {
	Subject     string       `json:"subject"`
	Recipient   string       `json:"recipient"`
	Attachments []attachment `json:"attachments"`
}

type oracle struct {
	mu       sync.Mutex
	state    snapshot
	expected expected
	root     string
}

func newOracle(root string, want expected) *oracle {
	return &oracle{root: root, expected: want, state: snapshot{
		SchemaVersion: 1,
		RunID:         want.RunID,
		Errors:        []string{},
		Drafts:        []draftEntry{},
		StartedAt:     time.Now().UTC(),
	}}
}

func (o *oracle) failureLocked(err error) {
	o.state.Failed = true
	o.state.Rejected++
	o.state.Errors = append(o.state.Errors, err.Error())
}

func (o *oracle) latchLocked(err error) {
	o.state.Failed = true
	o.state.Errors = append(o.state.Errors, err.Error())
}

func (o *oracle) fail(err error) {
	o.mu.Lock()
	defer o.mu.Unlock()
	o.latchLocked(err)
}

func (o *oracle) rejectRequest(err error) {
	o.mu.Lock()
	defer o.mu.Unlock()
	o.failureLocked(err)
}

func (o *oracle) current() snapshot {
	o.mu.Lock()
	defer o.mu.Unlock()
	copy := o.state
	copy.Errors = append([]string(nil), o.state.Errors...)
	copy.Drafts = append([]draftEntry(nil), o.state.Drafts...)
	return copy
}

func (o *oracle) writeAtomic(path string, value any) error {
	data, err := json.MarshalIndent(value, "", "  ")
	if err == nil {
		data = append(data, '\n')
		err = os.MkdirAll(filepath.Dir(path), 0o700)
	}
	if err == nil {
		var f *os.File
		f, err = os.CreateTemp(filepath.Dir(path), ".snapshot-*.tmp")
		if err == nil {
			name := f.Name()
			defer os.Remove(name)
			if err = f.Chmod(0o600); err == nil {
				_, err = f.Write(data)
			}
			if err == nil {
				err = f.Sync()
			}
			closeErr := f.Close()
			if err == nil {
				err = closeErr
			}
			if err == nil {
				err = os.Rename(name, path)
			}
		}
	}
	if err != nil {
		o.fail(fmt.Errorf("evidence snapshot write failed: %w", err))
	}
	return err
}

func (o *oracle) recordRequest() {
	o.mu.Lock()
	o.state.Requests++
	o.mu.Unlock()
}

func (o *oracle) acceptDraft(entry draftEntry) {
	o.mu.Lock()
	defer o.mu.Unlock()
	if o.state.AcceptedDraft > 0 {
		o.failureLocked(errors.New("late duplicate draft request"))
		return
	}
	o.state.AcceptedDraft++
	o.state.Drafts = append(o.state.Drafts, entry)
}

func (o *oracle) attemptDraft() {
	o.mu.Lock()
	o.state.DraftAttempts++
	o.mu.Unlock()
}

func (o *oracle) finalize(path string) error {
	o.mu.Lock()
	o.state.Final = true
	o.state.FinalizedAt = time.Now().UTC()
	value := o.state
	o.mu.Unlock()
	if err := o.writeAtomic(path, value); err != nil {
		return err
	}
	return nil
}

func readFinalSnapshot(path, runID string) (snapshot, error) {
	data, err := os.ReadFile(path)
	if err != nil {
		return snapshot{}, fmt.Errorf("read final fake snapshot: %w", err)
	}
	var result snapshot
	if err := json.Unmarshal(data, &result); err != nil {
		return snapshot{}, fmt.Errorf("decode final fake snapshot: %w", err)
	}
	if !result.Final || result.SchemaVersion != 1 || result.RunID != runID {
		return snapshot{}, errors.New("fake snapshot is not a finalized result for this run")
	}
	return result, nil
}

func (o *oracle) serve(ctx context.Context, listener net.Listener, cert tls.Certificate) error {
	var handlers sync.WaitGroup
	go func() {
		<-ctx.Done()
		_ = listener.Close()
	}()
	for {
		conn, err := listener.Accept()
		if err != nil {
			if errors.Is(err, net.ErrClosed) || ctx.Err() != nil {
				break
			}
			o.fail(fmt.Errorf("accept loop: %w", err))
			break
		}
		handlers.Add(1)
		go func() {
			defer handlers.Done()
			if err := o.serveConn(conn, cert); err != nil {
				o.fail(err)
			}
		}()
	}
	drained := make(chan struct{})
	go func() { handlers.Wait(); close(drained) }()
	select {
	case <-drained:
		return nil
	case <-time.After(8 * time.Second):
		o.fail(errors.New("fake request drain timed out"))
		return errors.New("fake request drain timed out")
	}
}

func (o *oracle) serveConn(raw net.Conn, cert tls.Certificate) error {
	defer raw.Close()
	if err := raw.SetDeadline(time.Now().Add(30 * time.Second)); err != nil {
		return fmt.Errorf("set request deadline: %w", err)
	}
	connect, err := http.ReadRequest(bufio.NewReader(raw))
	if err != nil {
		return fmt.Errorf("read proxy request: %w", err)
	}
	if connect.Method != http.MethodConnect || connect.Host != "www.googleapis.com:443" {
		_, _ = io.WriteString(raw, "HTTP/1.1 403 Forbidden\r\nContent-Length: 0\r\nConnection: close\r\n\r\n")
		return fmt.Errorf("rejected proxy destination %q %q", connect.Method, connect.Host)
	}
	if _, err := io.WriteString(raw, "HTTP/1.1 200 Connection established\r\n\r\n"); err != nil {
		return fmt.Errorf("write proxy response: %w", err)
	}
	tlsConn := tls.Server(raw, &tls.Config{Certificates: []tls.Certificate{cert}, MinVersion: tls.VersionTLS12})
	if err := tlsConn.Handshake(); err != nil {
		return fmt.Errorf("fake TLS handshake: %w", err)
	}
	request, err := http.ReadRequest(bufio.NewReader(tlsConn))
	if err != nil {
		return fmt.Errorf("read HTTPS request: %w", err)
	}
	o.recordRequest()
	if request.Header.Get("Authorization") != "Bearer "+syntheticToken {
		return o.reject(tlsConn, fmt.Errorf("unexpected synthetic authorization header"))
	}
	if request.Host != "www.googleapis.com" {
		return o.reject(tlsConn, fmt.Errorf("unexpected fake HTTPS host %q", request.Host))
	}
	var body string
	switch {
	case request.Method == http.MethodGet && request.URL.Path == "/oauth2/v3/userinfo":
		o.mu.Lock()
		o.state.UserInfo++
		o.mu.Unlock()
		body = `{"email":"test@example.invalid","name":"Synthetic 569"}`
	case request.Method == http.MethodPost && request.URL.Path == "/gmail/v1/users/me/drafts":
		o.mu.Lock()
		o.state.DraftRequests++
		o.mu.Unlock()
		o.attemptDraft()
		entry, err := o.checkDraft(request.Body)
		if err != nil {
			return o.reject(tlsConn, err)
		}
		o.acceptDraft(entry)
		body = `{"id":"fake569"}`
	default:
		return o.reject(tlsConn, fmt.Errorf("unexpected fake route %s %s", request.Method, request.URL.Path))
	}
	if _, err := fmt.Fprintf(tlsConn, "HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: %d\r\nConnection: close\r\n\r\n%s", len(body), body); err != nil {
		return fmt.Errorf("write fake response: %w", err)
	}
	return nil
}

func (o *oracle) reject(conn net.Conn, err error) error {
	_, _ = io.WriteString(conn, "HTTP/1.1 400 Bad Request\r\nContent-Length: 0\r\nConnection: close\r\n\r\n")
	o.rejectRequest(err)
	return nil
}

func (o *oracle) checkDraft(body io.Reader) (draftEntry, error) {
	var payload struct {
		Message struct {
			Raw string `json:"raw"`
		} `json:"message"`
	}
	if err := json.NewDecoder(body).Decode(&payload); err != nil {
		return draftEntry{}, fmt.Errorf("decode draft JSON: %w", err)
	}
	raw, err := base64.RawURLEncoding.DecodeString(payload.Message.Raw)
	if err != nil {
		return draftEntry{}, fmt.Errorf("decode Gmail raw message: %w", err)
	}
	message, err := mail.ReadMessage(bytes.NewReader(raw))
	if err != nil {
		return draftEntry{}, fmt.Errorf("parse RFC822 message: %w", err)
	}
	entry := draftEntry{Subject: message.Header.Get("Subject"), Recipient: message.Header.Get("To"), Attachments: []attachment{}}
	if entry.Subject != o.expected.Subject || !strings.Contains(strings.ToLower(entry.Recipient), strings.ToLower(o.expected.Recipient)) {
		return draftEntry{}, fmt.Errorf("draft envelope did not match run expectation")
	}
	mediaType, params, err := mime.ParseMediaType(message.Header.Get("Content-Type"))
	if err != nil || !strings.HasPrefix(strings.ToLower(mediaType), "multipart/") {
		return draftEntry{}, fmt.Errorf("draft is not a readable multipart message")
	}
	reader := multipart.NewReader(message.Body, params["boundary"])
	seen := make(map[string]bool)
	for {
		part, err := reader.NextPart()
		if errors.Is(err, io.EOF) {
			break
		}
		if err != nil {
			return draftEntry{}, fmt.Errorf("read MIME part: %w", err)
		}
		name := part.FileName()
		if name == "" {
			continue
		}
		if seen[name] {
			return draftEntry{}, fmt.Errorf("duplicate attachment %q", name)
		}
		wantHash, ok := o.expected.Attachments[name]
		if !ok {
			return draftEntry{}, fmt.Errorf("unexpected attachment %q", name)
		}
		var data []byte
		if strings.EqualFold(part.Header.Get("Content-Transfer-Encoding"), "base64") {
			data, err = io.ReadAll(base64.NewDecoder(base64.StdEncoding, part))
		} else {
			data, err = io.ReadAll(part)
		}
		if err != nil {
			return draftEntry{}, fmt.Errorf("read attachment %q: %w", name, err)
		}
		digest := sha256.Sum256(data)
		actualHash := hex.EncodeToString(digest[:])
		if actualHash != strings.ToLower(wantHash) {
			return draftEntry{}, fmt.Errorf("attachment bytes mismatch for %q", name)
		}
		seen[name] = true
		entry.Attachments = append(entry.Attachments, attachment{Name: name, Length: len(data), SHA256: actualHash})
	}
	if len(seen) != len(o.expected.Attachments) {
		return draftEntry{}, fmt.Errorf("attachment set incomplete: got %d, want %d", len(seen), len(o.expected.Attachments))
	}
	sort.Slice(entry.Attachments, func(i, j int) bool { return entry.Attachments[i].Name < entry.Attachments[j].Name })
	return entry, nil
}

func generateCertificate(root, runID string) (tls.Certificate, string, error) {
	key, err := rsa.GenerateKey(rand.Reader, 2048)
	if err != nil {
		return tls.Certificate{}, "", err
	}
	serial, err := rand.Int(rand.Reader, new(big.Int).Lsh(big.NewInt(1), 120))
	if err != nil {
		return tls.Certificate{}, "", err
	}
	now := time.Now().UTC()
	ca := &x509.Certificate{SerialNumber: serial, Subject: pkix.Name{CommonName: "Ticket 569 synthetic CA " + runID}, NotBefore: now.Add(-time.Minute), NotAfter: now.Add(2 * time.Hour), IsCA: true, BasicConstraintsValid: true, KeyUsage: x509.KeyUsageCertSign | x509.KeyUsageDigitalSignature}
	caDER, err := x509.CreateCertificate(rand.Reader, ca, ca, &key.PublicKey, key)
	if err != nil {
		return tls.Certificate{}, "", err
	}
	leafSerial, err := rand.Int(rand.Reader, new(big.Int).Lsh(big.NewInt(1), 120))
	if err != nil {
		return tls.Certificate{}, "", err
	}
	leaf := &x509.Certificate{SerialNumber: leafSerial, DNSNames: []string{"www.googleapis.com"}, NotBefore: ca.NotBefore, NotAfter: ca.NotAfter, KeyUsage: x509.KeyUsageDigitalSignature, ExtKeyUsage: []x509.ExtKeyUsage{x509.ExtKeyUsageServerAuth}}
	leafDER, err := x509.CreateCertificate(rand.Reader, leaf, ca, &key.PublicKey, key)
	if err != nil {
		return tls.Certificate{}, "", err
	}
	if err := os.MkdirAll(root, 0o700); err != nil {
		return tls.Certificate{}, "", err
	}
	caPath := filepath.Join(root, "test-ca.pem")
	if err := os.WriteFile(caPath, pem.EncodeToMemory(&pem.Block{Type: "CERTIFICATE", Bytes: caDER}), 0o600); err != nil {
		return tls.Certificate{}, "", err
	}
	thumbprint := sha256.Sum256(caDER)
	return tls.Certificate{Certificate: [][]byte{leafDER, caDER}, PrivateKey: key}, hex.EncodeToString(thumbprint[:]), nil
}

func run() int {
	root := flag.String("root", "", "run evidence directory")
	listen := flag.String("listen", "127.0.0.1:0", "loopback listen address")
	wantPath := flag.String("expected", "", "expected draft JSON")
	flag.Parse()
	if *root == "" || *wantPath == "" {
		fmt.Fprintln(os.Stderr, "--root and --expected are required")
		return 2
	}
	var want expected
	data, err := os.ReadFile(*wantPath)
	if err == nil {
		err = json.Unmarshal(data, &want)
	}
	if err != nil || want.RunID == "" || strings.Trim(want.RunID, "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-_") != "" || want.Subject == "" || want.Recipient == "" || len(want.Attachments) == 0 {
		fmt.Fprintln(os.Stderr, "invalid expected draft specification")
		return 2
	}
	if err := os.MkdirAll(*root, 0o700); err != nil {
		fmt.Fprintln(os.Stderr, err)
		return 2
	}
	o := newOracle(*root, want)
	cert, thumbprint, err := generateCertificate(*root, want.RunID)
	if err != nil {
		o.fail(fmt.Errorf("generate synthetic certificate: %w", err))
		_ = o.finalize(filepath.Join(*root, "fake-final.json"))
		return 1
	}
	listener, err := net.Listen("tcp", *listen)
	if err != nil {
		o.fail(fmt.Errorf("bind fake endpoint: %w", err))
		_ = o.finalize(filepath.Join(*root, "fake-final.json"))
		return 1
	}
	addr := listener.Addr().String()
	controlListener, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		o.fail(fmt.Errorf("bind local shutdown control: %w", err))
		_ = listener.Close()
		_ = o.finalize(filepath.Join(*root, "fake-final.json"))
		return 1
	}
	controlToken := make([]byte, 32)
	if _, err := rand.Read(controlToken); err != nil {
		o.fail(fmt.Errorf("create local shutdown token: %w", err))
		_ = listener.Close()
		_ = controlListener.Close()
		_ = o.finalize(filepath.Join(*root, "fake-final.json"))
		return 1
	}
	control := map[string]string{"address": controlListener.Addr().String(), "token": hex.EncodeToString(controlToken)}
	if err := o.writeAtomic(filepath.Join(*root, "fake-control.json"), control); err != nil {
		_ = listener.Close()
		_ = controlListener.Close()
		_ = o.finalize(filepath.Join(*root, "fake-final.json"))
		return 1
	}
	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()
	controlMux := http.NewServeMux()
	controlMux.HandleFunc("GET /status", func(w http.ResponseWriter, r *http.Request) {
		if _, err := hex.DecodeString(r.Header.Get("X-Test-Control")); err != nil || subtle.ConstantTimeCompare(mustDecodeHex(r.Header.Get("X-Test-Control")), controlToken) != 1 {
			http.Error(w, "forbidden", http.StatusForbidden)
			return
		}
		w.Header().Set("Content-Type", "application/json")
		_ = json.NewEncoder(w).Encode(o.current())
	})
	controlMux.HandleFunc("POST /shutdown", func(w http.ResponseWriter, r *http.Request) {
		provided, err := hex.DecodeString(r.Header.Get("X-Test-Control"))
		if err != nil || subtle.ConstantTimeCompare(provided, controlToken) != 1 {
			http.Error(w, "forbidden", http.StatusForbidden)
			return
		}
		w.WriteHeader(http.StatusAccepted)
		cancel()
	})
	controlServer := &http.Server{Handler: controlMux, ReadHeaderTimeout: 2 * time.Second}
	go func() {
		if err := controlServer.Serve(controlListener); err != nil && !errors.Is(err, http.ErrServerClosed) {
			o.fail(fmt.Errorf("control listener: %w", err))
			cancel()
		}
	}()
	ready := map[string]any{"schemaVersion": 1, "runId": want.RunID, "address": addr, "pid": os.Getpid(), "caThumbprintSHA256": thumbprint, "readyAt": time.Now().UTC()}
	if err := o.writeAtomic(filepath.Join(*root, "fake-ready.json"), ready); err != nil {
		_ = listener.Close()
		_ = o.finalize(filepath.Join(*root, "fake-final.json"))
		return 1
	}
	fmt.Printf("FAKE_READY %s\n", addr)
	signals := make(chan os.Signal, 1)
	signal.Notify(signals, os.Interrupt, syscall.SIGTERM)
	go func() {
		select {
		case <-signals:
			cancel()
		case <-ctx.Done():
		}
	}()
	serveErr := o.serve(ctx, listener, cert)
	shutdownCtx, shutdownCancel := context.WithTimeout(context.Background(), 3*time.Second)
	if err := controlServer.Shutdown(shutdownCtx); err != nil {
		o.fail(fmt.Errorf("control server shutdown: %w", err))
	}
	shutdownCancel()
	signal.Stop(signals)
	if serveErr != nil {
		o.fail(serveErr)
	}
	if err := o.finalize(filepath.Join(*root, "fake-final.json")); err != nil {
		fmt.Fprintln(os.Stderr, err)
		return 1
	}
	checked, err := readFinalSnapshot(filepath.Join(*root, "fake-final.json"), want.RunID)
	if err != nil {
		fmt.Fprintln(os.Stderr, err)
		return 1
	}
	if checked.Failed {
		fmt.Fprintln(os.Stderr, "FAKE_FAILED")
		return 1
	}
	fmt.Println("FAKE_FINAL")
	return 0
}

func mustDecodeHex(value string) []byte {
	decoded, err := hex.DecodeString(value)
	if err != nil {
		return nil
	}
	return decoded
}

func main() { os.Exit(run()) }
