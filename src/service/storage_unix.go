//go:build !windows

package service

import (
	"errors"
	"fmt"
	"os"
	"path/filepath"
)

type unixStoragePlatform struct{}

func newStoragePlatform() storagePlatform { return unixStoragePlatform{} }

func (unixStoragePlatform) ensureRoot(root string, access storageAccess) error {
	mode := os.FileMode(0700)
	if access == publicReadStorage {
		mode = 0755
	}
	if err := os.MkdirAll(root, mode); err != nil {
		return err
	}
	return os.Chmod(root, mode)
}

func (unixStoragePlatform) checkPath(root, path string, mustExist bool) error {
	relative, err := filepath.Rel(root, path)
	if err != nil || relative == ".." || (len(relative) > 3 && relative[:3] == ".."+string(filepath.Separator)) {
		return errors.New("protected path escapes root")
	}
	current := root
	parts := []string{}
	if relative != "." {
		parts = splitPath(relative)
	}
	for index, part := range parts {
		current = filepath.Join(current, part)
		info, statErr := os.Lstat(current)
		if errors.Is(statErr, os.ErrNotExist) && !mustExist && index == len(parts)-1 {
			return nil
		}
		if statErr != nil {
			return statErr
		}
		if info.Mode()&os.ModeSymlink != 0 {
			return errors.New("protected path traverses a symbolic link")
		}
	}
	rootInfo, err := os.Lstat(root)
	if err != nil {
		return err
	}
	if rootInfo.Mode()&os.ModeSymlink != 0 || !rootInfo.IsDir() {
		return errors.New("protected root is not a real directory")
	}
	return nil
}

func splitPath(path string) []string {
	var parts []string
	for path != "." && path != string(filepath.Separator) && path != "" {
		directory, name := filepath.Split(path)
		if name != "" {
			parts = append([]string{name}, parts...)
		}
		path = filepath.Clean(directory)
	}
	return parts
}

func (unixStoragePlatform) replace(source, destination string) error {
	return os.Rename(source, destination)
}

func (unixStoragePlatform) syncDirectory(path string) error {
	directory, err := os.Open(path)
	if err != nil {
		return err
	}
	if err := directory.Sync(); err != nil {
		_ = directory.Close()
		return fmt.Errorf("flush directory: %w", err)
	}
	return directory.Close()
}
