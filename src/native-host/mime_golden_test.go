package main

import (
	"bytes"
	"flag"
	"os"
	"path/filepath"
	"regexp"
	"strings"
	"testing"

	mapi "github.com/marcfargas/go-mapi/internal/mapi"
)

// GOTEST-02: Golden-file tests for buildFullMIME.
//
// The multipart boundary in buildFullMIME is "go_mapi_<pid>", which is
// non-deterministic across runs. normalizeMIMEBoundary rewrites it to a
// fixed placeholder before comparison so goldens are stable. Run
//
//	go test -run TestBuildFullMIME_Golden ./... -update
//
// to regenerate golden files after an intentional encoding change.

var updateGoldens = flag.Bool("update", false, "regenerate MIME golden files under testdata/mime")

var mimeBoundaryRE = regexp.MustCompile(`go_mapi_\d+`)

// normalizeMIMEBoundary replaces go_mapi_<pid> with go_mapi_PID so tests
// can compare byte-for-byte against a committed fixture.
func normalizeMIMEBoundary(b []byte) []byte {
	return mimeBoundaryRE.ReplaceAll(b, []byte("go_mapi_PID"))
}

// writeAttachment persists an in-memory blob to a temporary file and
// returns the absolute path. Used by the attachment golden cases so no
// binary fixtures are committed to the repo.
func writeAttachment(t *testing.T, dir, name string, data []byte) string {
	t.Helper()
	p := filepath.Join(dir, name)
	if err := os.WriteFile(p, data, 0o644); err != nil {
		t.Fatalf("write attachment: %v", err)
	}
	return p
}

func TestBuildFullMIME_Golden(t *testing.T) {
	tmp := t.TempDir()

	// Pre-build attachments used by the spaces / non-ascii cases.
	attachSpaces := writeAttachment(t, tmp, "report final.txt", []byte("attached body with spaces\n"))
	attachNonASCII := writeAttachment(t, tmp, "resume.pdf", []byte("fake pdf bytes"))

	// Long body ~12KB of repeated ASCII — large enough to exercise the
	// 76-char base64 line wrapping path multiple times.
	longBody := strings.Repeat("The quick brown fox jumps over the lazy dog. ", 300)

	// Body containing the literal substring "go_mapi_" — regression guard
	// against removing base64 encoding (which would expose the boundary
	// marker inside the body).
	collisionBody := "Watch for --go_mapi_PID markers in this body — they must be base64-wrapped."

	cases := []struct {
		name string
		mail *mapi.MailMessage
	}{
		{
			name: "utf8_subject",
			mail: &mapi.MailMessage{
				Version:    1,
				Timestamp:  "2026-04-10T00:00:00Z",
				Subject:    "Héllo Wörld",
				Body:       "plain body",
				BodyFormat: "plain",
				Recipients: mapi.Recipients{
					To: []mapi.Recipient{{Name: "Alice", Address: "alice@example.com"}},
				},
			},
		},
		{
			name: "attachment_spaces",
			mail: &mapi.MailMessage{
				Version:    1,
				Timestamp:  "2026-04-10T00:00:00Z",
				Subject:    "With spaced attachment",
				Body:       "see attached",
				BodyFormat: "plain",
				Recipients: mapi.Recipients{
					To: []mapi.Recipient{{Address: "bob@example.com"}},
				},
				Attachments: []mapi.Attachment{{
					Filename: "report final.txt",
					Path:     attachSpaces,
					Size:     0,
				}},
			},
		},
		{
			name: "attachment_nonascii",
			mail: &mapi.MailMessage{
				Version:    1,
				Timestamp:  "2026-04-10T00:00:00Z",
				Subject:    "Curriculum",
				Body:       "attached résumé",
				BodyFormat: "plain",
				Recipients: mapi.Recipients{
					To: []mapi.Recipient{{Address: "hr@example.com"}},
				},
				Attachments: []mapi.Attachment{{
					Filename: "résumé.pdf",
					Path:     attachNonASCII,
					Size:     0,
				}},
			},
		},
		{
			name: "boundary_collision",
			mail: &mapi.MailMessage{
				Version:    1,
				Timestamp:  "2026-04-10T00:00:00Z",
				Subject:    "Boundary collision",
				Body:       collisionBody,
				BodyFormat: "plain",
				Recipients: mapi.Recipients{
					To: []mapi.Recipient{{Address: "security@example.com"}},
				},
			},
		},
		{
			name: "long_body",
			mail: &mapi.MailMessage{
				Version:    1,
				Timestamp:  "2026-04-10T00:00:00Z",
				Subject:    "Long body",
				Body:       longBody,
				BodyFormat: "plain",
				Recipients: mapi.Recipients{
					To: []mapi.Recipient{{Address: "long@example.com"}},
				},
			},
		},
		{
			name: "empty_body",
			mail: &mapi.MailMessage{
				Version:    1,
				Timestamp:  "2026-04-10T00:00:00Z",
				Subject:    "Empty body",
				Body:       "",
				BodyFormat: "plain",
				Recipients: mapi.Recipients{
					To: []mapi.Recipient{{Address: "void@example.com"}},
				},
			},
		},
	}

	for _, tc := range cases {
		tc := tc
		t.Run(tc.name, func(t *testing.T) {
			got, err := mapi.BuildFullMIME(tc.mail)
			if err != nil {
				t.Fatalf("buildFullMIME error: %v", err)
			}
			normalized := normalizeMIMEBoundary(got)

			goldenPath := filepath.Join("testdata", "mime", tc.name+".golden")

			if *updateGoldens {
				if err := os.MkdirAll(filepath.Dir(goldenPath), 0o755); err != nil {
					t.Fatalf("mkdir testdata: %v", err)
				}
				if err := os.WriteFile(goldenPath, normalized, 0o644); err != nil {
					t.Fatalf("write golden: %v", err)
				}
				t.Logf("updated %s (%d bytes)", goldenPath, len(normalized))
				return
			}

			want, err := os.ReadFile(goldenPath)
			if err != nil {
				t.Fatalf("read golden %s: %v (run with -update to regenerate)", goldenPath, err)
			}
			if !bytes.Equal(normalized, want) {
				t.Errorf("MIME mismatch for %s\n--- got ---\n%s\n--- want ---\n%s",
					tc.name, truncate(normalized, 400), truncate(want, 400))
			}
		})
	}
}

func truncate(b []byte, n int) string {
	if len(b) <= n {
		return string(b)
	}
	return string(b[:n]) + "…"
}
