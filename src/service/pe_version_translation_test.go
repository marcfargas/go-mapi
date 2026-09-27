package service

import (
	"reflect"
	"testing"
)

func TestProductVersionQueryKeys(t *testing.T) {
	for _, tc := range []struct {
		name         string
		translations []byte
		want         []string
		bad          bool
	}{
		{"Wails neutral", []byte{0x00, 0x00, 0xb0, 0x04}, []string{`\StringFileInfo\000004b0\ProductVersion`}, false},
		{"service English", []byte{0x09, 0x04, 0xb0, 0x04}, []string{`\StringFileInfo\040904b0\ProductVersion`}, false},
		{"multiple declared", []byte{0x00, 0x00, 0xb0, 0x04, 0x09, 0x04, 0xb0, 0x04}, []string{`\StringFileInfo\000004b0\ProductVersion`, `\StringFileInfo\040904b0\ProductVersion`}, false},
		{"missing", nil, nil, true},
		{"partial", []byte{0x00, 0x00, 0xb0}, nil, true},
		{"duplicate", []byte{0x00, 0x00, 0xb0, 0x04, 0x00, 0x00, 0xb0, 0x04}, nil, true},
	} {
		t.Run(tc.name, func(t *testing.T) {
			got, err := productVersionQueryKeys(tc.translations)
			if (err != nil) != tc.bad || (!tc.bad && !reflect.DeepEqual(got, tc.want)) {
				t.Fatalf("keys=%q error=%v, want=%q bad=%v", got, err, tc.want, tc.bad)
			}
		})
	}
}
