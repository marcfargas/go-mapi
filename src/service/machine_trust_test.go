package service

import (
	"errors"
	"testing"
)

func TestEmbeddedMachineMetadataOrigin(t *testing.T) {
	prior := MachineReleaseMetadataOrigin
	t.Cleanup(func() { MachineReleaseMetadataOrigin = prior })
	MachineReleaseMetadataOrigin = ""
	if _, err := EmbeddedMachineMetadataOrigin(); !errors.Is(err, ErrMachineTrustUnavailable) {
		t.Fatalf("missing origin: %v", err)
	}
	MachineReleaseMetadataOrigin = "https://go-mapi.app"
	if got, err := EmbeddedMachineMetadataOrigin(); err != nil || got != MachineReleaseMetadataOrigin {
		t.Fatalf("origin = %q, %v", got, err)
	}
	for _, invalid := range []string{"http://go-mapi.app", "https://other.test/path", "https://user@go-mapi.app", "https://go-mapi.app?target=x"} {
		MachineReleaseMetadataOrigin = invalid
		if _, err := EmbeddedMachineMetadataOrigin(); err == nil {
			t.Fatalf("accepted origin %q", invalid)
		}
	}
}
