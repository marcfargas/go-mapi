package mapi

import (
	"fmt"
	"strconv"
	"strings"
)

// CounterpartRequirement is the deliberately small, cross-language range
// grammar used by components.json and embedded release metadata.
type CounterpartRequirement struct {
	Component    string `json:"component"`
	MinInclusive string `json:"minInclusive"`
	MaxExclusive string `json:"maxExclusive,omitempty"`
}

type CompatibilityStatus string

const (
	CompatibilityCompatible CompatibilityStatus = "compatible"
	CompatibilityMissing    CompatibilityStatus = "missing"
	CompatibilityInvalid    CompatibilityStatus = "invalid"
	CompatibilityBelowMin   CompatibilityStatus = "below-minimum"
	CompatibilityAboveMax   CompatibilityStatus = "above-maximum"
)

type CompatibilityResult struct {
	Status           CompatibilityStatus    `json:"status"`
	Component        string                 `json:"component"`
	InstalledVersion string                 `json:"installedVersion,omitempty"`
	Required         CounterpartRequirement `json:"required"`
	Action           string                 `json:"action"`
}

// EvaluateCompatibility applies canonical SemVer 2.0 precedence to structured
// bounds. Build metadata is retained for diagnostics and ignored for ordering.
func EvaluateCompatibility(installed string, required CounterpartRequirement, action string) CompatibilityResult {
	result := CompatibilityResult{Component: required.Component, InstalledVersion: installed, Required: required, Action: action}
	if installed == "" {
		result.Status = CompatibilityMissing
		return result
	}
	got, err := parseStrictSemVer(installed)
	if err != nil {
		result.Status = CompatibilityInvalid
		return result
	}
	minimum, err := parseStrictSemVer(required.MinInclusive)
	if err != nil || required.Component == "" {
		result.Status = CompatibilityInvalid
		return result
	}
	var maximum *semVersion
	if required.MaxExclusive != "" {
		parsed, err := parseStrictSemVer(required.MaxExclusive)
		if err != nil || parsed.compare(minimum) <= 0 {
			result.Status = CompatibilityInvalid
			return result
		}
		maximum = &parsed
	}
	if got.compare(minimum) < 0 {
		result.Status = CompatibilityBelowMin
		return result
	}
	if maximum != nil {
		if got.compare(*maximum) >= 0 {
			result.Status = CompatibilityAboveMax
			return result
		}
	}
	result.Status = CompatibilityCompatible
	return result
}

func IsStrictReleaseVersion(value string) bool {
	if value == "0.0.0-dev" {
		return false
	}
	_, err := parseStrictSemVer(value)
	return err == nil
}

type semVersion struct {
	major, minor, patch uint64
	pre                 []string
}

func parseStrictSemVer(value string) (semVersion, error) {
	var result semVersion
	if value == "" || strings.TrimSpace(value) != value || strings.HasPrefix(value, "v") {
		return result, fmt.Errorf("non-canonical version %q", value)
	}
	coreAndPre := value
	if plus := strings.IndexByte(value, '+'); plus >= 0 {
		coreAndPre = value[:plus]
		if !validIdentifiers(value[plus+1:], false) {
			return result, fmt.Errorf("invalid build metadata")
		}
	}
	core := coreAndPre
	if dash := strings.IndexByte(coreAndPre, '-'); dash >= 0 {
		core = coreAndPre[:dash]
		pre := coreAndPre[dash+1:]
		if !validIdentifiers(pre, true) {
			return result, fmt.Errorf("invalid prerelease")
		}
		result.pre = strings.Split(pre, ".")
	}
	parts := strings.Split(core, ".")
	if len(parts) != 3 {
		return result, fmt.Errorf("version must contain major.minor.patch")
	}
	values := []*uint64{&result.major, &result.minor, &result.patch}
	for i, part := range parts {
		if !validNumeric(part) {
			return result, fmt.Errorf("invalid numeric component")
		}
		n, err := strconv.ParseUint(part, 10, 64)
		if err != nil {
			return result, err
		}
		*values[i] = n
	}
	return result, nil
}

func validNumeric(value string) bool {
	if value == "" || (len(value) > 1 && value[0] == '0') {
		return false
	}
	for _, ch := range value {
		if ch < '0' || ch > '9' {
			return false
		}
	}
	return true
}

func validIdentifiers(value string, prerelease bool) bool {
	if value == "" {
		return false
	}
	for _, id := range strings.Split(value, ".") {
		if id == "" {
			return false
		}
		numeric := true
		for _, ch := range id {
			if !((ch >= '0' && ch <= '9') || (ch >= 'A' && ch <= 'Z') || (ch >= 'a' && ch <= 'z') || ch == '-') {
				return false
			}
			if ch < '0' || ch > '9' {
				numeric = false
			}
		}
		if prerelease && numeric && len(id) > 1 && id[0] == '0' {
			return false
		}
	}
	return true
}

func (v semVersion) compare(other semVersion) int {
	for _, pair := range [][2]uint64{{v.major, other.major}, {v.minor, other.minor}, {v.patch, other.patch}} {
		if pair[0] < pair[1] {
			return -1
		}
		if pair[0] > pair[1] {
			return 1
		}
	}
	if len(v.pre) == 0 && len(other.pre) == 0 {
		return 0
	}
	if len(v.pre) == 0 {
		return 1
	}
	if len(other.pre) == 0 {
		return -1
	}
	for i := 0; i < len(v.pre) && i < len(other.pre); i++ {
		a, b := v.pre[i], other.pre[i]
		an, aerr := strconv.ParseUint(a, 10, 64)
		bn, berr := strconv.ParseUint(b, 10, 64)
		if aerr == nil && berr == nil {
			if an < bn {
				return -1
			}
			if an > bn {
				return 1
			}
			continue
		}
		if aerr == nil {
			return -1
		}
		if berr == nil {
			return 1
		}
		if a < b {
			return -1
		}
		if a > b {
			return 1
		}
	}
	if len(v.pre) < len(other.pre) {
		return -1
	}
	if len(v.pre) > len(other.pre) {
		return 1
	}
	return 0
}
