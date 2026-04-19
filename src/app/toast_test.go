package main

import "testing"

func TestToastErrorCopy(t *testing.T) {
	cases := map[string]string{
		"signed-out": toastCopyDraftFailedSignedOut,
		"network":    toastCopyDraftFailedNetwork,
		"gmail":      toastCopyDraftFailedGmail,
		"unknown":    toastCopyDraftFailedGmail, // fallback
	}
	for cat, want := range cases {
		if got := toastErrorCopy(cat); got != want {
			t.Errorf("toastErrorCopy(%q) = %q; want %q", cat, got, want)
		}
	}
}

func TestToastActivatorGUID_NotDefault(t *testing.T) {
	const defaultLibraryGUID = "{0F82E845-CB89-4039-BDBF-67CA33254C76}"
	if toastActivatorGUID == defaultLibraryGUID {
		t.Fatal("toastActivatorGUID must NOT be the jackmordaunt default (RESEARCH §9 landmine 2). Regenerate with [guid]::NewGuid() and pin.")
	}
	if toastActivatorGUID == "" || toastActivatorGUID == "{<REPLACE-WITH-GENERATED-GUID>}" {
		t.Fatal("toastActivatorGUID is unpinned — regenerate via [guid]::NewGuid() and commit the real value.")
	}
	// Sanity shape: {XXXXXXXX-XXXX-XXXX-XXXX-XXXXXXXXXXXX} = 38 chars.
	if len(toastActivatorGUID) != 38 {
		t.Errorf("toastActivatorGUID expected length 38 (with braces), got %d", len(toastActivatorGUID))
	}
}

func TestAUMIDsDistinct(t *testing.T) {
	if aumidDev == aumidProd {
		t.Error("aumidDev and aumidProd must be different — enables dev/prod coexistence on the same machine")
	}
}
