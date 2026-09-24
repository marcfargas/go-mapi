//go:build windows

package service

import (
	"fmt"
	"syscall"
	"testing"
)

func TestWindowsTrustUnavailable(t *testing.T) {
	for _, test := range []struct {
		name string
		code syscall.Errno
		want bool
	}{
		{"revocation server offline", 0x80092013, true},
		{"revocation result unavailable", 0x800B010E, true},
		{"no signature", 0x800B0100, false},
		{"untrusted root", 0x800B0109, false},
		{"revoked certificate", 0x800B010C, false},
	} {
		t.Run(test.name, func(t *testing.T) {
			if got := windowsTrustUnavailable(fmt.Errorf("Windows trust: %w", test.code)); got != test.want {
				t.Fatalf("windowsTrustUnavailable(%#x) = %t, want %t", uint32(test.code), got, test.want)
			}
		})
	}
}
