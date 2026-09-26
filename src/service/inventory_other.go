//go:build !windows

package service

func NewWindowsInstallerInventory() InstallerInventory {
	return NewInstallerInventory(unavailableInstallerAPI{})
}

type unavailableInstallerAPI struct{}

func (unavailableInstallerAPI) RelatedProducts(string) ([]string, error) {
	return nil, ErrWindowsInstallerUnavailable
}

func (unavailableInstallerAPI) ProductVersion(string) (string, error) {
	return "", ErrWindowsInstallerUnavailable
}
