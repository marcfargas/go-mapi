package mapi

import (
	"crypto/sha1"
	"encoding/hex"
	"fmt"
	"regexp"
	"strconv"
	"strings"
)

// MachineSKU identifies one permanent Windows Installer product family and
// release namespace. Values are deliberately closed: adding a SKU changes the
// signed release and installed-product contracts.
type MachineSKU string

const (
	MachineSKUSystem MachineSKU = "system"
	MachineSKUSuite  MachineSKU = "suite"
)

const machineProductCodeNamespace = "4D8E30F8-83CF-4A0E-9410-746D75A35705"

var machinePackageReleasePattern = regexp.MustCompile(`^(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)(?:-(alpha|beta|nightly)\.([1-9][0-9]*))?$`)

// MachinePackageIdentity is the deterministic publication and MSI identity of
// one immutable machine package release.
type MachinePackageIdentity struct {
	SKU            MachineSKU `json:"sku"`
	Release        string     `json:"release"`
	ProductVersion string     `json:"productVersion"`
	ProductCode    string     `json:"productCode"`
	Tag            string     `json:"tag"`
	AssetName      string     `json:"assetName"`
	ManifestName   string     `json:"manifestName"`
	TargetPath     string     `json:"targetPath"`
	Sequence       uint64     `json:"sequence"`
}

// ValidateMachinePackageSuccessor prevents replay and ProductVersion
// collisions inside one release track. Cross-SKU comparisons are invalid
// because each family has an independent monotonic sequence.
func ValidateMachinePackageSuccessor(previous, next MachinePackageIdentity) error {
	if previous.SKU != next.SKU {
		return fmt.Errorf("cannot compare package release tracks %q and %q", previous.SKU, next.SKU)
	}
	if next.Sequence <= previous.Sequence {
		return fmt.Errorf("package release %q (%s) does not succeed %q (%s)", next.Release, next.ProductVersion, previous.Release, previous.ProductVersion)
	}
	return nil
}

// NewMachinePackageIdentity validates the channel policy and derives every
// identifier that must agree across the MSI, release assets and signed target.
func NewMachinePackageIdentity(sku MachineSKU, release string) (MachinePackageIdentity, error) {
	if sku != MachineSKUSystem && sku != MachineSKUSuite {
		return MachinePackageIdentity{}, fmt.Errorf("unknown machine SKU %q", sku)
	}
	match := machinePackageReleasePattern.FindStringSubmatch(release)
	if match == nil {
		return MachinePackageIdentity{}, fmt.Errorf("invalid package release %q", release)
	}

	major, err := strconv.ParseUint(match[1], 10, 64)
	if err != nil {
		return MachinePackageIdentity{}, fmt.Errorf("invalid package major in %q", release)
	}
	minor, err := strconv.ParseUint(match[2], 10, 64)
	if err != nil {
		return MachinePackageIdentity{}, fmt.Errorf("invalid package minor in %q", release)
	}
	patch, err := strconv.ParseUint(match[3], 10, 64)
	if err != nil {
		return MachinePackageIdentity{}, fmt.Errorf("invalid package patch in %q", release)
	}
	stage, counter := match[4], match[5]
	if major > 255 || minor > 255 {
		return MachinePackageIdentity{}, fmt.Errorf("package release %q exceeds MSI major/minor bounds", release)
	}

	build := patch
	if stage == "" {
		if major%2 != 0 {
			return MachinePackageIdentity{}, fmt.Errorf("stable package release %q must use an even major", release)
		}
		if patch > 65535 {
			return MachinePackageIdentity{}, fmt.Errorf("package release %q exceeds MSI build bound", release)
		}
	} else {
		if major%2 != 1 {
			return MachinePackageIdentity{}, fmt.Errorf("development package release %q must use an odd major", release)
		}
		if patch > 65 {
			return MachinePackageIdentity{}, fmt.Errorf("development package release %q exceeds encodable patch bound", release)
		}
		n, err := strconv.ParseUint(counter, 10, 64)
		if err != nil {
			return MachinePackageIdentity{}, fmt.Errorf("invalid development counter in %q", release)
		}
		if n == 0 || n > 99 {
			return MachinePackageIdentity{}, fmt.Errorf("development package release %q has an invalid counter", release)
		}
		stageCode := map[string]uint64{"alpha": 1, "beta": 2, "nightly": 3}[stage]
		build = patch*1000 + stageCode*100 + n
	}

	productCode, err := uuidV5(machineProductCodeNamespace, "go-mapi/msi/"+string(sku)+"/"+release)
	if err != nil {
		return MachinePackageIdentity{}, err
	}
	prefix := "go-mapi-" + string(sku) + "-" + release
	return MachinePackageIdentity{
		SKU:            sku,
		Release:        release,
		ProductVersion: fmt.Sprintf("%d.%d.%d", major, minor, build),
		ProductCode:    productCode,
		Tag:            string(sku) + "-v" + release,
		AssetName:      prefix + "-x64.msi",
		ManifestName:   prefix + ".manifest.json",
		TargetPath:     "/machine/" + string(sku) + "/targets.json",
		Sequence:       major<<24 | minor<<16 | build,
	}, nil
}

func uuidV5(namespace, name string) (string, error) {
	namespaceBytes, err := hex.DecodeString(strings.ReplaceAll(namespace, "-", ""))
	if err != nil || len(namespaceBytes) != 16 {
		return "", fmt.Errorf("invalid UUID namespace %q", namespace)
	}
	hash := sha1.New()
	_, _ = hash.Write(namespaceBytes)
	_, _ = hash.Write([]byte(name))
	uuid := hash.Sum(nil)[:16]
	uuid[6] = uuid[6]&0x0f | 0x50
	uuid[8] = uuid[8]&0x3f | 0x80
	return strings.ToUpper(fmt.Sprintf("%x-%x-%x-%x-%x", uuid[0:4], uuid[4:6], uuid[6:8], uuid[8:10], uuid[10:16])), nil
}
