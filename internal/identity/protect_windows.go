//go:build windows

package identity

import (
	"errors"
	"runtime"
	"syscall"
	"unsafe"
)

var (
	crypt32       = syscall.NewLazyDLL("crypt32.dll")
	protectData   = crypt32.NewProc("CryptProtectData")
	unprotectData = crypt32.NewProc("CryptUnprotectData")
	localFree     = syscall.NewLazyDLL("kernel32.dll").NewProc("LocalFree")
)

type dataBlob struct {
	size uint32
	data *byte
}
type dpapi struct{}

func platformProtector() (protector, error)       { return dpapi{}, nil }
func (dpapi) protect(data []byte) ([]byte, error) { return transform(protectData, data, maxPlainBytes) }
func (dpapi) unprotect(data []byte) ([]byte, error) {
	return transform(unprotectData, data, maxFileBytes)
}

func transform(proc *syscall.LazyProc, data []byte, limit int) ([]byte, error) {
	return transformBound(proc, data, limit, "MicDrop host identity / DPAPI / version 1")
}

type pairingDPAPI struct{}

func (pairingDPAPI) protect(data []byte) ([]byte, error) {
	return transformBound(protectData, data, MaxPairingBytes, "MicDrop paired devices / DPAPI / version 1")
}
func (pairingDPAPI) unprotect(data []byte) ([]byte, error) {
	return transformBound(unprotectData, data, maxFileBytes, "MicDrop paired devices / DPAPI / version 1")
}
func platformPairingProtector() (protector, error) { return pairingDPAPI{}, nil }

type remoteDPAPI struct{}

func (remoteDPAPI) protect(data []byte) ([]byte, error) {
	return transformBound(protectData, data, 4096, "MicDrop remote connection / DPAPI / version 1")
}
func (remoteDPAPI) unprotect(data []byte) ([]byte, error) {
	return transformBound(unprotectData, data, maxFileBytes, "MicDrop remote connection / DPAPI / version 1")
}
func platformRemoteProtector() (protector, error) { return remoteDPAPI{}, nil }

func transformBound(proc *syscall.LazyProc, data []byte, limit int, purpose string) ([]byte, error) {
	if len(data) == 0 || len(data) > limit {
		return nil, errors.New("invalid protected data size")
	}
	if proc.Find() != nil || localFree.Find() != nil {
		return nil, ErrUnavailable
	}
	// Public application/version binding, not an additional secret or a key.
	entropy := []byte(purpose)
	in := dataBlob{uint32(len(data)), &data[0]}
	binding := dataBlob{uint32(len(entropy)), &entropy[0]}
	var out dataBlob
	const uiForbidden = 1 // Current-user scope; never CRYPTPROTECT_LOCAL_MACHINE.
	success, _, _ := proc.Call(uintptr(unsafe.Pointer(&in)), 0,
		uintptr(unsafe.Pointer(&binding)), 0, 0, uiForbidden, uintptr(unsafe.Pointer(&out)))
	runtime.KeepAlive(data)
	runtime.KeepAlive(entropy)
	if out.data != nil {
		defer localFree.Call(uintptr(unsafe.Pointer(out.data)))
	}
	if success == 0 {
		return nil, errors.New("Windows data protection failed")
	}
	if out.data == nil || out.size == 0 || out.size > maxFileBytes {
		return nil, ErrInvalid
	}
	buffer := unsafe.Slice(out.data, int(out.size))
	result := append([]byte(nil), buffer...)
	clear(buffer)
	return result, nil
}
