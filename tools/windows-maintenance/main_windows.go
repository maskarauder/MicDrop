// windows-maintenance is a small, DLL-independent installer helper.
package main

import (
	"debug/buildinfo"
	"errors"
	"flag"
	"fmt"
	"os"
	"path/filepath"
	"strings"
	"time"
	"unsafe"

	"golang.org/x/sys/windows"
)

const hostPackage = "github.com/maskarauder/MicDrop/apps/windows-host"

func main() {
	// Tests narrow this to their unique fixture. It can never expand ownership
	// beyond the current account or bypass the executable identity check.
	scope := flag.String("scope", "", "only stop MicDrop executables within this absolute directory")
	flag.Parse()
	if flag.NArg() != 0 || (*scope != "" && !filepath.IsAbs(*scope)) {
		fmt.Fprintln(os.Stderr, "maintenance requires an absolute optional --scope")
		os.Exit(2)
	}
	if err := stopHosts(*scope); err != nil {
		fmt.Fprintln(os.Stderr, err)
		os.Exit(1)
	}
}

func withinScope(path, scope string) bool {
	if scope == "" {
		return true
	}
	rel, err := filepath.Rel(strings.ToLower(filepath.Clean(scope)), strings.ToLower(filepath.Clean(path)))
	return err == nil && rel != ".." && !strings.HasPrefix(rel, `..\`) && !filepath.IsAbs(rel)
}

func trustedHost(path, scope string) bool {
	name := filepath.Base(path)
	if (!strings.EqualFold(name, "MicDrop.exe") && !strings.EqualFold(name, "windows-host.exe")) || !withinScope(path, scope) {
		return false
	}
	info, err := buildinfo.ReadFile(path)
	return err == nil && info.Path == hostPackage && info.Main.Path == "github.com/maskarauder/MicDrop"
}

type hostProcess struct {
	pid    uint32
	handle windows.Handle
}

func sameUser(process windows.Handle, sid *windows.SID) bool {
	var token windows.Token
	if windows.OpenProcessToken(process, windows.TOKEN_QUERY, &token) != nil {
		return false
	}
	defer token.Close()
	user, err := token.GetTokenUser()
	return err == nil && user.User.Sid.Equals(sid)
}

func stopHosts(scope string) error {
	user, err := windows.GetCurrentProcessToken().GetTokenUser()
	if err != nil {
		return err
	}
	snapshot, err := windows.CreateToolhelp32Snapshot(windows.TH32CS_SNAPPROCESS, 0)
	if err != nil {
		return err
	}
	defer windows.CloseHandle(snapshot)
	var hosts []hostProcess
	defer func() {
		for _, host := range hosts {
			windows.CloseHandle(host.handle)
		}
	}()
	entry := windows.ProcessEntry32{Size: uint32(unsafe.Sizeof(windows.ProcessEntry32{}))}
	for err = windows.Process32First(snapshot, &entry); err == nil; err = windows.Process32Next(snapshot, &entry) {
		name := windows.UTF16ToString(entry.ExeFile[:])
		if entry.ProcessID == windows.GetCurrentProcessId() || (!strings.EqualFold(name, "MicDrop.exe") && !strings.EqualFold(name, "windows-host.exe")) {
			continue
		}
		query, e := windows.OpenProcess(windows.PROCESS_QUERY_LIMITED_INFORMATION|windows.SYNCHRONIZE, false, entry.ProcessID)
		if e != nil {
			continue // Inaccessible/other-account processes are never terminated.
		}
		var path [32768]uint16
		length := uint32(len(path))
		owned := sameUser(query, user.User.Sid) && windows.QueryFullProcessImageName(query, 0, &path[0], &length) == nil && trustedHost(windows.UTF16ToString(path[:length]), scope)
		if owned {
			// Keep query open while obtaining the termination handle, so the PID
			// cannot be reused between identity verification and termination.
			handle, e := windows.OpenProcess(windows.PROCESS_TERMINATE|windows.SYNCHRONIZE, false, entry.ProcessID)
			if e != nil {
				windows.CloseHandle(query)
				return fmt.Errorf("cannot close MicDrop process %d; exit it and retry: %w", entry.ProcessID, e)
			}
			hosts = append(hosts, hostProcess{entry.ProcessID, handle})
		}
		windows.CloseHandle(query)
	}
	if !errors.Is(err, windows.ERROR_NO_MORE_FILES) {
		return err
	}

	// The desktop's Exit action drains media/logs; WM_CLOSE only hides its tray
	// window. Command 109 is kept stable for older desktop builds as well.
	user32 := windows.NewLazySystemDLL("user32.dll")
	class, _ := windows.UTF16PtrFromString("MicDrop.Desktop." + user.User.Sid.String())
	hwnd, _, _ := user32.NewProc("FindWindowW").Call(uintptr(unsafe.Pointer(class)), 0)
	var guiPID uint32
	user32.NewProc("GetWindowThreadProcessId").Call(hwnd, uintptr(unsafe.Pointer(&guiPID)))
	for _, host := range hosts {
		if hwnd != 0 && host.pid == guiPID {
			ok, _, _ := user32.NewProc("PostMessageW").Call(hwnd, 0x111, 109, 0)
			if ok != 0 {
				windows.WaitForSingleObject(host.handle, 10000)
			}
		}
	}
	for _, host := range hosts {
		state, e := windows.WaitForSingleObject(host.handle, 0)
		if e != nil {
			return e
		}
		if state != windows.WAIT_OBJECT_0 {
			if e := windows.TerminateProcess(host.handle, 0); e != nil {
				if state, _ := windows.WaitForSingleObject(host.handle, 0); state == windows.WAIT_OBJECT_0 {
					continue
				}
				return fmt.Errorf("cannot stop MicDrop process %d: %w", host.pid, e)
			}
		}
	}
	deadline := time.Now().Add(5 * time.Second)
	for _, host := range hosts {
		remaining := max(0, time.Until(deadline).Milliseconds())
		state, e := windows.WaitForSingleObject(host.handle, uint32(remaining))
		if e != nil || state != windows.WAIT_OBJECT_0 {
			return fmt.Errorf("MicDrop process %d did not finish shutdown", host.pid)
		}
	}
	return nil
}
