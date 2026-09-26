package service

import (
	"encoding/binary"
	"errors"
	"fmt"
)

// The Windows version resource declares language/codepage pairs as DWORDs in
// \VarFileInfo\Translation. Query only those declared StringFileInfo tables.
func productVersionQueryKeys(translations []byte) ([]string, error) {
	if len(translations) == 0 || len(translations) > 256 || len(translations)%4 != 0 {
		return nil, errors.New("invalid PE version translations")
	}
	keys := make([]string, 0, len(translations)/4)
	seen := make(map[uint32]bool, len(translations)/4)
	for i := 0; i < len(translations); i += 4 {
		language := binary.LittleEndian.Uint16(translations[i:])
		codepage := binary.LittleEndian.Uint16(translations[i+2:])
		pair := uint32(language)<<16 | uint32(codepage)
		if seen[pair] {
			return nil, errors.New("duplicate PE version translation")
		}
		seen[pair] = true
		keys = append(keys, fmt.Sprintf(`\StringFileInfo\%04x%04x\ProductVersion`, language, codepage))
	}
	return keys, nil
}
