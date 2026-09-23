package update

import "testing"

func TestVerifyPublisherIdentity(t *testing.T) {
	policy := PublisherPolicy{Publisher: "Azure Trusted Signing", EKUs: []string{"1.3.6.1.5.5.7.3.3", "1.3.6.1.4.1.311.84.1.1"}, PolicyID: "azure-artifact-signing"}
	valid := AuthenticodeIdentity{ChainValid: true, Publisher: " azure trusted signing ", EKUs: append([]string(nil), policy.EKUs...)}
	tests := []struct {
		name     string
		policy   PublisherPolicy
		identity AuthenticodeIdentity
		wantErr  bool
	}{
		{name: "matching signer", policy: policy, identity: valid},
		{name: "invalid chain", policy: policy, identity: AuthenticodeIdentity{Publisher: valid.Publisher, EKUs: valid.EKUs}, wantErr: true},
		{name: "wrong publisher", policy: policy, identity: AuthenticodeIdentity{ChainValid: true, Publisher: "Other", EKUs: valid.EKUs}, wantErr: true},
		{name: "missing subscriber EKU", policy: policy, identity: AuthenticodeIdentity{ChainValid: true, Publisher: valid.Publisher, EKUs: valid.EKUs[:1]}, wantErr: true},
		{name: "unconfigured policy", identity: valid, wantErr: true},
	}
	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			err := VerifyPublisherIdentity(tt.policy, tt.identity)
			if (err != nil) != tt.wantErr {
				t.Fatalf("VerifyPublisherIdentity error = %v, wantErr %t", err, tt.wantErr)
			}
		})
	}
}

func TestMatchPublisherPolicy(t *testing.T) {
	protected := PublisherPolicy{Publisher: "Azure Trusted Signing", EKUs: []string{"1.3.6.1.5.5.7.3.3", "1.3.6.1.4.1.311.84.1.1"}, PolicyID: "azure-artifact-signing"}
	for _, test := range []struct {
		name   string
		policy PublisherPolicy
		valid  bool
	}{
		{"same", protected, true},
		{"reordered EKUs", PublisherPolicy{Publisher: protected.Publisher, EKUs: []string{protected.EKUs[1], protected.EKUs[0]}, PolicyID: protected.PolicyID}, true},
		{"wrong policy ID", PublisherPolicy{Publisher: protected.Publisher, EKUs: protected.EKUs, PolicyID: "other"}, false},
		{"wrong publisher", PublisherPolicy{Publisher: "Other", EKUs: protected.EKUs, PolicyID: protected.PolicyID}, false},
		{"missing EKU", PublisherPolicy{Publisher: protected.Publisher, EKUs: protected.EKUs[:1], PolicyID: protected.PolicyID}, false},
		{"extra EKU", PublisherPolicy{Publisher: protected.Publisher, EKUs: append(append([]string{}, protected.EKUs...), "1.2.3.4"), PolicyID: protected.PolicyID}, false},
	} {
		t.Run(test.name, func(t *testing.T) {
			if err := MatchPublisherPolicy(protected, test.policy); (err == nil) != test.valid {
				t.Fatalf("match error = %v, want valid %t", err, test.valid)
			}
		})
	}
}
