// SPDX-License-Identifier: MPL-2.0
//go:build (darwin && arm64) || (linux && amd64)

package desktop

import (
	"errors"
	"fmt"
	"os"
	"path/filepath"
	"strconv"
	"strings"
	"syscall"
)

func acquireInstanceLock(directory string) (*os.File, bool, error) {
	if !filepath.IsAbs(directory) {
		return nil, false, errors.New("desktop state directory must be an absolute path")
	}
	if err := os.MkdirAll(directory, 0700); err != nil {
		return nil, false, err
	}
	lockPath := filepath.Join(directory, "desktop.lock")
	if info, err := os.Lstat(lockPath); err == nil && !info.Mode().IsRegular() {
		return nil, false, errors.New("desktop lock must be a regular file")
	}
	file, err := os.OpenFile(lockPath, os.O_CREATE|os.O_RDWR, 0600)
	if err != nil {
		return nil, false, err
	}
	if err := syscall.Flock(int(file.Fd()), syscall.LOCK_EX|syscall.LOCK_NB); err != nil {
		if errors.Is(err, syscall.EWOULDBLOCK) || errors.Is(err, syscall.EAGAIN) {
			data, _ := os.ReadFile(lockPath)
			_ = file.Close()
			if pid, parseErr := strconv.Atoi(strings.TrimSpace(string(data))); parseErr == nil && pid > 1 {
				_ = syscall.Kill(pid, syscall.SIGUSR1)
			}
			return nil, true, nil
		}
		_ = file.Close()
		return nil, false, err
	}
	_ = file.Truncate(0)
	_, _ = file.Seek(0, 0)
	_, _ = fmt.Fprintf(file, "%d\n", os.Getpid())
	_ = file.Sync()
	return file, false, nil
}
