package update

import (
	"errors"
	"slices"
	"strings"
)

// AuthenticodeIdentity is the signer identity after chain validation. Publisher
// policy must still be checked before treating the file as authorized.
type AuthenticodeIdentity struct {
	ChainValid bool
	Publisher  string
	EKUs       []string
}

// VerifyPublisherIdentity binds a validated signer to a configured policy.
// PolicyID is an application-level identity, not a certificate extension; the
// caller must compare it with its protected/signed release policy separately.
func VerifyPublisherIdentity(policy PublisherPolicy, identity AuthenticodeIdentity) error {
	if err := validatePublisher(policy); err != nil {
		return err
	}
	if !identity.ChainValid {
		return errors.New("Authenticode chain is not valid")
	}
	if strings.ToLower(strings.TrimSpace(identity.Publisher)) != strings.ToLower(strings.TrimSpace(policy.Publisher)) {
		return errors.New("Authenticode publisher does not match policy")
	}
	for _, eku := range policy.EKUs {
		if !slices.Contains(identity.EKUs, eku) {
			return errors.New("Authenticode signer lacks required EKU")
		}
	}
	return nil
}
