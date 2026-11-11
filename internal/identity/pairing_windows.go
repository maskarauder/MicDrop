//go:build windows

package identity

import (
	"io"
	"os"
	"syscall"
	"unsafe"
)

func lockPairing(path string) (io.Closer, error) {
	p, err := syscall.UTF16PtrFromString(path)
	if err != nil {
		return nil, err
	}
	h, err := syscall.CreateFile(p, syscall.GENERIC_READ|syscall.GENERIC_WRITE, 0, nil,
		syscall.OPEN_ALWAYS, syscall.FILE_ATTRIBUTE_NORMAL, 0)
	if err != nil {
		return nil, err
	}
	return os.NewFile(uintptr(h), path), nil
}

var movePairing = syscall.NewLazyDLL("kernel32.dll").NewProc("MoveFileExW")

func replacePairing(from, to string) error {
	f, err := syscall.UTF16PtrFromString(from)
	if err != nil {
		return err
	}
	t, err := syscall.UTF16PtrFromString(to)
	if err != nil {
		return err
	}
	// Same-volume replacement of an already flushed file; wait for disk writes.
	ok, _, callErr := movePairing.Call(uintptr(unsafe.Pointer(f)), uintptr(unsafe.Pointer(t)), 1|8)
	if ok == 0 {
		return callErr
	}
	return nil
}
