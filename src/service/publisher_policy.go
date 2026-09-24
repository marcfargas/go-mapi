package service

import (
	"bytes"
	"encoding/base64"
	"encoding/json"
	"errors"
	"fmt"
	"io"

	"github.com/marcfargas/go-mapi/internal/mapi/update"
)

// PublisherPolicyB64 is set at build time from the protected release
// environment. An empty value is allowed for unsigned development builds,
// but never authorizes an installation.
var PublisherPolicyB64 string

// Version is the canonical service release linked into the executable.
var Version string

var ErrPublisherPolicyUnavailable = errors.New("embedded publisher policy is unavailable")

func EmbeddedPublisherPolicy() (update.PublisherPolicy, error) {
	if PublisherPolicyB64 == "" {
		return update.PublisherPolicy{}, ErrPublisherPolicyUnavailable
	}
	if len(PublisherPolicyB64) > 8192 {
		return update.PublisherPolicy{}, errors.New("embedded publisher policy exceeds bound")
	}
	data, err := base64.StdEncoding.Strict().DecodeString(PublisherPolicyB64)
	if err != nil {
		return update.PublisherPolicy{}, fmt.Errorf("decode embedded publisher policy: %w", err)
	}
	decoder := json.NewDecoder(bytes.NewReader(data))
	decoder.DisallowUnknownFields()
	var policy update.PublisherPolicy
	if err := decoder.Decode(&policy); err != nil {
		return update.PublisherPolicy{}, fmt.Errorf("parse embedded publisher policy: %w", err)
	}
	var extra any
	if err := decoder.Decode(&extra); !errors.Is(err, io.EOF) {
		return update.PublisherPolicy{}, errors.New("embedded publisher policy has trailing data")
	}
	if err := update.ValidatePublisherPolicy(policy); err != nil {
		return update.PublisherPolicy{}, fmt.Errorf("validate embedded publisher policy: %w", err)
	}
	return policy, nil
}
