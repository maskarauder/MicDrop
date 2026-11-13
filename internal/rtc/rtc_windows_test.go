// SPDX-License-Identifier: MPL-2.0
//go:build windows

package rtc

import (
	"fmt"
	"runtime"
	"runtime/debug"
	"syscall"
	"testing"
	"unsafe"
)

//go:noinline
func forceStackGrowthForTest(depth int) byte {
	var scratch [4096]byte
	scratch[0] = byte(depth)
	scratch[len(scratch)-1] = byte(depth >> 8)
	if depth > 0 {
		scratch[1] = forceStackGrowthForTest(depth - 1)
	}
	return scratch[0] ^ scratch[1] ^ scratch[len(scratch)-1]
}

func TestWindowsApplyICEPreservesServerPointersAcrossStackGrowthAndGC(t *testing.T) {
	type nativeServerAddrs struct {
		url, username, credential uintptr
	}

	moveMemory := syscall.NewLazyDLL("ntdll.dll").NewProc("RtlMoveMemory")
	lstrlenA := syscall.NewLazyDLL("kernel32.dll").NewProc("lstrlenA")

	readCString := func(addr uintptr) string {
		if addr == 0 {
			return ""
		}
		n, _, _ := lstrlenA.Call(addr)
		if n == 0 {
			return ""
		}
		raw := make([]byte, int(n))
		moveMemory.Call(uintptr(unsafe.Pointer(&raw[0])), addr, n)
		runtime.KeepAlive(raw)
		return string(raw)
	}
	writeError := func(msgAddr, msgLen uintptr, text string) {
		raw := append([]byte(text), 0)
		count := min(len(raw), int(msgLen))
		if msgAddr != 0 && count > 0 {
			moveMemory.Call(msgAddr, uintptr(unsafe.Pointer(&raw[0])), uintptr(count))
			runtime.KeepAlive(raw)
		}
	}

	var gotHandle, gotForce uintptr
	var gotServers []ICEServer
	var sink byte

	cb := syscall.NewCallback(func(handle, serversAddr, count, force, msgAddr, msgLen uintptr) uintptr {
		// Force deep goroutine stack growth and full GC cycles inside the native
		// callback before dereferencing serversAddr or any inner C-string pointer.
		sink ^= forceStackGrowthForTest(64)
		for i := 0; i < 64; i++ {
			buf := make([]byte, 256)
			buf[0] = byte(i)
			sink ^= buf[0]
		}
		runtime.GC()
		debug.FreeOSMemory()
		runtime.GC()

		gotHandle = handle
		gotForce = force
		gotServers = nil
		if count > 0 {
			if serversAddr == 0 {
				writeError(msgAddr, msgLen, "null servers pointer for non-empty count")
				return 1
			}
			entries := make([]nativeServerAddrs, int(count))
			moveMemory.Call(uintptr(unsafe.Pointer(&entries[0])), serversAddr, uintptr(count)*unsafe.Sizeof(nativeServerAddrs{}))
			runtime.KeepAlive(entries)
			gotServers = make([]ICEServer, int(count))
			for i, entry := range entries {
				gotServers[i] = ICEServer{
					URL:        readCString(entry.url),
					Username:   readCString(entry.username),
					Credential: readCString(entry.credential),
				}
			}
		} else if serversAddr != 0 {
			writeError(msgAddr, msgLen, "expected null servers pointer for empty count")
			return 1
		}
		return 0
	})

	call := func(handle uintptr, servers *nativeICEServer, count, force uintptr, message *byte, messageLen uintptr) uintptr {
		result, _, _ := syscall.SyscallN(
			cb,
			handle,
			uintptr(unsafe.Pointer(servers)),
			count,
			force,
			uintptr(unsafe.Pointer(message)),
			messageLen,
		)
		runtime.KeepAlive(servers)
		runtime.KeepAlive(message)
		return result
	}

	const testHandle = uintptr(0x55AA1234)

	// 0 servers
	if err := applyICEWith(call, testHandle, ICEConfig{ForceRelay: false}); err != nil {
		t.Fatalf("0-server applyICEWith failed: %v", err)
	}
	if gotHandle != testHandle || gotForce != 0 || len(gotServers) != 0 {
		t.Fatalf("unexpected 0-server callback args: handle=%#x force=%d servers=%+v", gotHandle, gotForce, gotServers)
	}

	// 1 server (exact small-slice case that previously stayed on the stack)
	for iter := 0; iter < 50; iter++ {
		want := ICEConfig{
			ForceRelay: iter%2 == 1,
			Servers: []ICEServer{{
				URL:        fmt.Sprintf("turns:turn-%d.example.net:5349?transport=tcp", iter),
				Username:   fmt.Sprintf("ephemeral-user-%d", iter),
				Credential: fmt.Sprintf("ephemeral-secret-%d", iter),
			}},
		}
		// Run in a fresh goroutine so the initial 2 KB stack must grow inside cb.
		errCh := make(chan error, 1)
		go func() {
			errCh <- applyICEWith(call, testHandle, want)
		}()
		if err := <-errCh; err != nil {
			t.Fatalf("iter %d: 1-server applyICEWith failed: %v", iter, err)
		}
		wantForce := uintptr(0)
		if want.ForceRelay {
			wantForce = 1
		}
		if gotHandle != testHandle || gotForce != wantForce || len(gotServers) != 1 || gotServers[0] != want.Servers[0] {
			t.Fatalf("iter %d: 1-server mismatch: got (%#x, %d, %+v), want (%#x, %d, %+v)",
				iter, gotHandle, gotForce, gotServers, testHandle, wantForce, want.Servers)
		}
	}

	// 3 servers
	multi := ICEConfig{
		ForceRelay: true,
		Servers: []ICEServer{
			{URL: "stun:stun.example.net:3478"},
			{URL: "turn:turn.example.net:3478?transport=udp", Username: "u1", Credential: "c1"},
			{URL: "turns:turn.example.net:5349?transport=tcp", Username: "u2", Credential: "c2"},
		},
	}
	errCh := make(chan error, 1)
	go func() {
		errCh <- applyICEWith(call, testHandle, multi)
	}()
	if err := <-errCh; err != nil {
		t.Fatalf("3-server applyICEWith failed: %v", err)
	}
	if len(gotServers) != len(multi.Servers) {
		t.Fatalf("3-server count = %d, want %d", len(gotServers), len(multi.Servers))
	}
	for i := range multi.Servers {
		if gotServers[i] != multi.Servers[i] {
			t.Fatalf("server[%d] = %+v, want %+v", i, gotServers[i], multi.Servers[i])
		}
	}
	runtime.KeepAlive(sink)
}
