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

// ValidatePublisherPolicy checks public build-time signer policy before a
// release source or native verifier is used.
func ValidatePublisherPolicy(policy PublisherPolicy) error { return validatePublisher(policy) }

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

// MatchPublisherPolicy prevents authenticated targets from selecting a signer
// policy different from the one protected by the service executable.
func MatchPublisherPolicy(expected, actual PublisherPolicy) error {
	if err := validatePublisher(expected); err != nil {
		return err
	}
	if err := validatePublisher(actual); err != nil {
		return err
	}
	if expected.PolicyID != actual.PolicyID ||
		strings.ToLower(strings.TrimSpace(expected.Publisher)) != strings.ToLower(strings.TrimSpace(actual.Publisher)) ||
		len(expected.EKUs) != len(actual.EKUs) {
		return errors.New("release publisher policy does not match protected policy")
	}
	for _, eku := range expected.EKUs {
		if !slices.Contains(actual.EKUs, eku) {
			return errors.New("release publisher policy does not match protected policy")
		}
	}
	return nil
}
