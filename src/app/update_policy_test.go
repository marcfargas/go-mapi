package main

import (
	"testing"
	"time"

	"github.com/marcfargas/go-mapi/internal/mapi"
)

func TestUpdatePolicyUsesOnlySupportedUserActions(t *testing.T) {
	raw := UpdateState{UpdateAvailable: true, LatestVersion: "4.0.1", InstallerURL: "https://go-mapi.app/downloads/app/4.0.1/x64", InterceptorUpdateAvailable: true}
	standalone := effectiveUpdateState(raw, "standalone", publicMachineStatus{})
	if !standalone.UpdateAvailable || standalone.UpdateActionURL != raw.InstallerURL || !validUpdateActionURL(standalone) {
		t.Fatalf("standalone action = %+v", standalone)
	}
	store := effectiveUpdateState(raw, "store", publicMachineStatus{})
	if !store.UpdateAvailable || store.InstallerURL != "" || store.UpdateActionURL != storeUpdatesURI || !validUpdateActionURL(store) {
		t.Fatalf("Store action = %+v", store)
	}
	for _, channel := range []string{"machine", "unknown"} {
		visible := effectiveUpdateState(raw, channel, publicMachineStatus{})
		if visible.UpdateAvailable || visible.InterceptorUpdateAvailable || visible.UpdateActionURL != "" || visible.UpdateGuidance == "" {
			t.Fatalf("%s guidance = %+v", channel, visible)
		}
	}
	if raw.InstallerURL == "" || !raw.UpdateAvailable || !raw.InterceptorUpdateAvailable {
		t.Fatal("policy mutated the raw cached offer")
	}
}

func TestUpdatePolicyRejectsUntrustedRouteAndKeepsRepairGuidance(t *testing.T) {
	raw := UpdateState{UpdateAvailable: true, InstallerURL: "https://example.com/installer.exe"}
	standalone := effectiveUpdateState(raw, "standalone", publicMachineStatus{})
	if !standalone.UpdateAvailable || standalone.UpdateActionURL != "" {
		t.Fatalf("untrusted route was offered: %+v", standalone)
	}
	machine := effectiveUpdateState(raw, "machine", publicMachineStatus{Trusted: true, Status: mapi.PublicStatusV2{Health: "repair-required", UpdatedAt: time.Now()}})
	if machine.UpdateGuidance != "The machine installation needs repair. Contact your administrator." {
		t.Fatalf("repair guidance = %q", machine.UpdateGuidance)
	}
}

func TestUpdatePolicySuppressesOnlyVerifiedAutomaticManagement(t *testing.T) {
	now := time.Now().UTC()
	status := mapi.PublicStatusV2{
		Schema: mapi.PublicStatusSchemaV2, SKU: "system", PackageVersion: "4.0.0", InterceptorVersion: "4.0.0",
		Health: "healthy", Updates: "enabled", Capability: "automatic", Code: "pending",
		Checker: "no-update", UpdatedAt: now, HealthObservedAt: now, LastSuccessAt: now,
		CandidateExpiresAt: now.Add(time.Hour), NextAttemptAt: now.Add(30 * time.Minute),
	}
	identity := mapi.InstalledStatusIdentity{SKU: "system", PackageVersion: "4.0.0", InterceptorVersion: "4.0.0"}
	raw := UpdateState{InterceptorUpdateAvailable: true, Compatibility: "incompatible"}
	managed := effectiveUpdateState(raw, "standalone", publicMachineStatus{Status: status, Identity: identity, ServiceRunning: true, Trusted: true})
	if managed.InterceptorUpdateAvailable || !managed.ManagedSystemUpdate || managed.Compatibility != raw.Compatibility {
		t.Fatalf("effective management should suppress only redundant notice: %+v, status validation=%v, predicate=%v", managed, mapi.ValidatePublicStatusV2(status), mapi.ManagedSystemUpdateEffective(status, identity, true, now))
	}
	for name, machine := range map[string]publicMachineStatus{
		"untrusted":  {Status: status, Identity: identity, ServiceRunning: true},
		"stopped":    {Status: status, Identity: identity, Trusted: true},
		"mismatched": {Status: status, Identity: mapi.InstalledStatusIdentity{SKU: "system", PackageVersion: "4.0.1", InterceptorVersion: "4.0.0"}, ServiceRunning: true, Trusted: true},
		"discovery":  {Status: func() mapi.PublicStatusV2 { s := status; s.Capability = "discovery"; return s }(), Identity: identity, ServiceRunning: true, Trusted: true},
	} {
		visible := effectiveUpdateState(raw, "standalone", machine)
		if !visible.InterceptorUpdateAvailable || visible.ManagedSystemUpdate {
			t.Fatalf("%s must retain notice: %+v", name, visible)
		}
	}
}
