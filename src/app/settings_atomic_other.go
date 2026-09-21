//go:build !windows

package main

import "os"

func moveFileAtomic(src, dst string) error { return os.Rename(src, dst) }
