package service

import (
	"errors"
	"os"
	"path/filepath"
	"testing"
	"time"
)

func TestSuiteDrainBoundsRetainOriginalForceExpiry(t *testing.T) {
	closed := time.Date(2026, 9, 26, 12, 0, 0, 0, time.UTC)
	deadline := closed.Add(suiteGraceDuration)
	cases := []struct {
		name         string
		now          time.Time
		grace, force time.Duration
	}{
		{"first close", closed, 30 * time.Second, 35 * time.Second},
		{"retry inside grace", closed.Add(27 * time.Second), 3 * time.Second, 8 * time.Second},
		{"retry inside force", closed.Add(33 * time.Second), 0, 2 * time.Second},
		{"recovery after expiry", closed.Add(time.Minute), 0, 0},
		{"implausible backward clock refuses", closed.Add(-time.Minute), 0, 0},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			graceEnd, forceEnd := suiteDrainBounds(tc.now, deadline)
			if got := graceEnd.Sub(tc.now); got != tc.grace {
				t.Fatalf("grace=%s, want %s", got, tc.grace)
			}
			if got := forceEnd.Sub(tc.now); got != tc.force {
				t.Fatalf("force=%s, want %s", got, tc.force)
			}
		})
	}
}

type failingSuiteByteFile struct {
	*os.File
	failSync     int
	failTruncate int
}

func (file *failingSuiteByteFile) Sync() error {
	if file.failSync > 0 {
		file.failSync--
		return errors.New("injected flush failure")
	}
	return file.File.Sync()
}

func (file *failingSuiteByteFile) Truncate(size int64) error {
	if file.failTruncate > 0 {
		file.failTruncate--
		return errors.New("injected truncate failure")
	}
	return file.File.Truncate(size)
}

func TestSuiteOpenWriteThenFlushFailureRestoresRefusal(t *testing.T) {
	for _, tc := range []struct {
		name            string
		flush, truncate int
	}{
		{"flush after O byte", 1, 0},
		{"truncate after O byte", 0, 1},
	} {
		t.Run(tc.name, func(t *testing.T) {
			path := filepath.Join(t.TempDir(), "suite-admission-v1")
			f, err := os.OpenFile(path, os.O_CREATE|os.O_RDWR, 0600)
			if err != nil {
				t.Fatal(err)
			}
			defer f.Close()
			if _, err := f.WriteAt([]byte{'C'}, 0); err != nil {
				t.Fatal(err)
			}
			if err := f.Sync(); err != nil {
				t.Fatal(err)
			}
			fault := &failingSuiteByteFile{File: f, failSync: tc.flush, failTruncate: tc.truncate}
			unsafe, err := writeSuiteByte(fault, 'O')
			if err == nil || unsafe {
				t.Fatalf("failed open: unsafe=%v err=%v", unsafe, err)
			}
			// A different handle models a later admission reader after writer
			// unlock. It must see a real C byte, not the O written before flush.
			reader, err := os.Open(path)
			if err != nil {
				t.Fatal(err)
			}
			defer reader.Close()
			var byteRead [1]byte
			if _, err := reader.ReadAt(byteRead[:], 0); err != nil || byteRead[0] != 'C' {
				t.Fatalf("reader saw %q after failed open: %v", byteRead, err)
			}
			if unsafe, err := writeSuiteByte(fault, 'O'); unsafe || err != nil {
				t.Fatalf("healthy retry: unsafe=%v err=%v", unsafe, err)
			}
			if _, err := reader.ReadAt(byteRead[:], 0); err != nil || byteRead[0] != 'O' {
				t.Fatalf("reader missed healthy retry: %q %v", byteRead, err)
			}
		})
	}
}

func TestSuiteOpenReportsUnrecoverableIOInsteadOfClaimingClosed(t *testing.T) {
	path := filepath.Join(t.TempDir(), "suite-admission-v1")
	f, err := os.OpenFile(path, os.O_CREATE|os.O_RDWR, 0600)
	if err != nil {
		t.Fatal(err)
	}
	defer f.Close()
	if _, err := f.WriteAt([]byte{'C'}, 0); err != nil {
		t.Fatal(err)
	}
	fault := &failingSuiteByteFile{File: f, failTruncate: 3}
	unsafe, err := writeSuiteByte(fault, 'O')
	if !unsafe || err == nil {
		t.Fatalf("failed original, rollback and malformed fallback: unsafe=%v err=%v", unsafe, err)
	}
}
