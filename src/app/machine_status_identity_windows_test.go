//go:build windows

package main

import (
	"strings"
	"testing"

	"golang.org/x/sys/windows"
)

func TestMachineMarkerACLInheritance(t *testing.T) {
	// Captured from the installed beta.3 Suite with unchanged beta.2 System
	// payloads. CREATOR OWNER is inheritance-only; all effective writers are
	// SYSTEM or Administrators.
	const installed = "O:SYG:SYD:AI(A;CIID;KR;;;BU)(A;CIID;KA;;;BA)(A;CIID;KA;;;SY)(A;CIIOID;KA;;;CO)(A;CIID;KR;;;AC)(A;CIID;KR;;;S-1-15-3-1024-1065365936-1281604716-3511738428-1654721687-432734479-3232135806-4053264122-3456934681)"
	for _, test := range []struct {
		name    string
		sddl    string
		trusted bool
	}{
		{"installed Suite", installed, true},
		{"Administrators owner", strings.Replace(installed, "O:SY", "O:BA", 1), true},
		{"effective creator owner write", strings.Replace(installed, "CIIOID", "CIID", 1), false},
		{"inherited Users write", strings.Replace(installed, "KR;;;BU", "KA;;;BU", 1), false},
		{"explicit Users write", "O:SYG:SYD:(A;;KA;;;SY)(A;;KW;;;BU)", false},
		{"generic Users write", "O:SYG:SYD:(A;;KA;;;SY)(A;;GW;;;BU)", false},
		{"Users can change DACL", "O:SYG:SYD:(A;;KA;;;SY)(A;;WD;;;BU)", false},
		{"Users can change owner", "O:SYG:SYD:(A;;KA;;;SY)(A;;WO;;;BU)", false},
		{"foreign owner", strings.Replace(installed, "O:SY", "O:BU", 1), false},
		{"missing owner", "D:(A;;KA;;;SY)", false},
		{"missing DACL", "O:SYG:SY", false},
		{"null DACL", "O:SYG:SYD:NO_ACCESS_CONTROL", false},
		{"unsupported effective ACE", "O:SYG:SYD:(OA;;KR;00000000-0000-0000-0000-000000000001;;BU)", false},
		{"unsupported inherit-only ACE", "O:SYG:SYD:(OA;CIIO;KR;00000000-0000-0000-0000-000000000001;;BU)", false},
	} {
		t.Run(test.name, func(t *testing.T) {
			sd, err := windows.SecurityDescriptorFromString(test.sddl)
			if err != nil {
				t.Fatal(err)
			}
			if got := trustedMachineMarkerSecurityDescriptor(sd); got != test.trusted {
				t.Fatalf("trusted = %v, want %v", got, test.trusted)
			}
		})
	}
	if trustedMachineMarkerSecurityDescriptor(nil) {
		t.Fatal("missing security descriptor trusted")
	}
}
