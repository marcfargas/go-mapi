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
