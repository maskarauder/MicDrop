// A disposable process fixture, built with an isolated module identity by the
// installer lifecycle test. It never reads actual MicDrop settings or devices.
package main

import (
	"flag"
	"os"
	"syscall"
	"time"
	"unsafe"
)

func main() {
	mutex := flag.String("mutex", "", "fixture mutex")
	lock := flag.String("lock", "", "existing fixture lock")
	ready := flag.String("ready", "", "ready marker")
	flag.Parse()
	if *mutex != "" {
		name, _ := syscall.UTF16PtrFromString(*mutex)
		handle, _, _ := syscall.NewLazyDLL("kernel32.dll").NewProc("CreateMutexW").Call(0, 0, uintptr(unsafe.Pointer(name)))
		if handle == 0 {
			os.Exit(2)
		}
		defer syscall.CloseHandle(syscall.Handle(handle))
	}
	if *lock != "" {
		path, _ := syscall.UTF16PtrFromString(*lock)
		handle, err := syscall.CreateFile(path, syscall.GENERIC_READ|syscall.GENERIC_WRITE, 0, nil, syscall.OPEN_EXISTING, 0, 0)
		if err != nil {
			os.Exit(3)
		}
		defer syscall.CloseHandle(handle)
	}
	if os.WriteFile(*ready, []byte("ready"), 0600) != nil {
		os.Exit(4)
	}
	for {
		time.Sleep(time.Hour) // Deliberately requires the forced-shutdown fallback.
	}
}
