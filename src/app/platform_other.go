//go:build !windows

package main

import (
	"context"
	"errors"
)

// The user-component core is platform neutral. These adapters isolate the
// Windows shell integrations so queue, auth, settings, and UI tests can run on
// any developer machine.
type unsupportedStartupService struct{}

func newStartupService() startupService { return unsupportedStartupService{} }
func (unsupportedStartupService) State(context.Context, bool) StartupState {
	return StartupState{Backend: "unsupported", Effective: "unavailable"}
}
func (unsupportedStartupService) Set(context.Context, bool) StartupState {
	return StartupState{Backend: "unsupported", Effective: "unavailable"}
}
func (unsupportedStartupService) OpenSettings() error {
	return errors.New("startup settings are only available on Windows")
}

type unsupportedHandoffPlatform struct{}

func newHandoffPlatform() handoffPlatform { return unsupportedHandoffPlatform{} }
func (unsupportedHandoffPlatform) CurrentChannel() (installChannel, error) {
	return channelStandalone, nil
}
func (unsupportedHandoffPlatform) IsInstalled(context.Context, installChannel) (bool, error) {
	return false, nil
}
func (unsupportedHandoffPlatform) RemoveSource(context.Context, installChannel) error     { return nil }
func (unsupportedHandoffPlatform) VerifyTargetOnly(context.Context, installChannel) error { return nil }
func (unsupportedHandoffPlatform) Activate(context.Context, installChannel) error         { return nil }

func startupHandoffAction(context.Context) (installChannel, error) { return "", nil }
func prepareStoreTargetHandoff(context.Context) error              { return nil }
func runStoreToStandaloneHandoff(context.Context) error            { return nil }

func acquireSingleInstance() (bool, error)                 { return false, nil }
func releaseSingleInstance()                               {}
func waitForRaiseSignal(done <-chan struct{}, _ func())    { <-done }
func waitForShutdownSignal(done <-chan struct{}, _ func()) { <-done }
func registerSessionEndHandler(func()) (func(), error)     { return func() {}, nil }
func runBoundedDrain(done context.Context, drain func()) {
	<-done.Done()
	drain()
}

type unavailableReleaseFetcher struct{}

func newUpdateCheckFetcher(string) releaseFetcher { return unavailableReleaseFetcher{} }
func (unavailableReleaseFetcher) FetchLatestRelease(context.Context) (*latestRelease, error) {
	return nil, errors.New("update checks are only available on Windows")
}
func allowedUpdateURL(string) bool { return false }

func (a *App) wireUpdateNotifications() {}
