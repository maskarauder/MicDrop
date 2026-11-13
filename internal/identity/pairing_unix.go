// SPDX-License-Identifier: MPL-2.0
//go:build darwin || linux

package identity

import (
	"errors"
	"io"
	"os"
	"path/filepath"
	"syscall"
)

func lockPairing(path string) (io.Closer, error) {
	fd, err := syscall.Open(path, syscall.O_RDWR|syscall.O_CREAT|syscall.O_CLOEXEC|syscall.O_NOFOLLOW, 0o600)
	if err != nil {
		return nil, err
	}
	var st syscall.Stat_t
	if err := syscall.Fstat(fd, &st); err != nil || (st.Mode&syscall.S_IFMT) != syscall.S_IFREG || int(st.Uid) != os.Geteuid() {
		_ = syscall.Close(fd)
		return nil, errors.New("invalid pairing lock file")
	}
	if err := syscall.Flock(fd, syscall.LOCK_EX|syscall.LOCK_NB); err != nil {
		_ = syscall.Close(fd)
		return nil, err
	}
	return os.NewFile(uintptr(fd), path), nil
}

func replacePairing(from, to string) error {
	if err := os.Rename(from, to); err != nil {
		return err
	}
	dir, err := os.Open(filepath.Dir(to))
	if err != nil {
		return err
	}
	syncErr := dir.Sync()
	closeErr := dir.Close()
	if syncErr != nil {
		return syncErr
	}
	return closeErr
}
