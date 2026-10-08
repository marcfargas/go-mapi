//go:build windows

package service

import (
	"github.com/marcfargas/go-mapi/internal/mapi/update"
	"testing"
	"time"
)

func TestProductionRecoveryWiringBothSKUs(t *testing.T) {
	for _, sku := range []update.SKU{update.System, update.Suite} {
		t.Run(string(sku), func(t *testing.T) {
			stateStorage := mustStorage(t, testStorageRoot(t, "state"), privateStorage)
			updates := mustStorage(t, testStorageRoot(t, "updates"), privateStorage)
			pending, _ := NewFileStateStore(stateStorage)
			replay, _ := NewFileReplayStore(stateStorage)
			last, _ := NewFileLastResultStore(stateStorage)
			c, err := newProductionMachineCoordinator(sku, stateStorage, updates, pending, replay, last, NewWindowsInstallerInventory())
			if err != nil {
				t.Fatal(err)
			}
			if c.deps.Recovery == nil || c.deps.RecoveryLock == nil || c.deps.PrepareAuthorization == nil {
				t.Fatal("production omitted recovery boundary")
			}
			unlock, err := c.deps.RecoveryLock()
			if err != nil {
				t.Fatal(err)
			}
			if second, err := c.deps.RecoveryLock(); err == nil {
				second()
				t.Fatal("kernel runner ownership allowed overlap")
			}
			unlock()
			launcher := c.deps.Launcher.(*DetachedRunnerLauncher)
			timeout := launcher.awaiter.(PollReadyAwaiter).Timeout
			expected := 30 * time.Second
			if sku == update.Suite {
				expected = 75 * time.Second
			}
			if timeout != expected {
				t.Fatal("readiness allowance changed")
			}
		})
	}
}
