//go:build !windows

package main

func publicUpdateState(raw UpdateState) UpdateState { return raw }
