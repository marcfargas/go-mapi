package mapi

import (
	"errors"
	"testing"
)

func TestMachineAdmissionByteRefusesUnknownProjection(t *testing.T) {
	for _, tc := range []struct {
		bytes []byte
		open  bool
		err   bool
	}{
		{[]byte{'O'}, true, false}, {[]byte{'C'}, false, false}, {nil, false, true}, {[]byte{'X'}, false, true}, {[]byte{'O', 'C'}, false, true},
	} {
		open, err := validMachineAdmissionByte(tc.bytes)
		if open != tc.open || (err != nil) != tc.err || tc.err && !errors.Is(err, ErrMachineAdmissionClosed) {
			t.Fatalf("byte %q: open=%v err=%v", tc.bytes, open, err)
		}
	}
}
