//go:build windows

package desktop

import (
	"errors"
	"fmt"
	"os"
	"path/filepath"
	"runtime"
	"syscall"
	"unicode/utf16"
	"unsafe"

	"golang.org/x/sys/windows"
	"golang.org/x/sys/windows/registry"
)

var (
	moveMemory         = windows.NewLazySystemDLL("ntdll.dll").NewProc("RtlMoveMemory")
	user32             = windows.NewLazySystemDLL("user32.dll")
	shell32            = windows.NewLazySystemDLL("shell32.dll")
	gdi32              = windows.NewLazySystemDLL("gdi32.dll")
	kernel32           = windows.NewLazySystemDLL("kernel32.dll")
	comdlg32           = windows.NewLazySystemDLL("comdlg32.dll")
	registerClass      = user32.NewProc("RegisterClassExW")
	unregisterClass    = user32.NewProc("UnregisterClassW")
	createWindow       = user32.NewProc("CreateWindowExW")
	defWindowProc      = user32.NewProc("DefWindowProcW")
	destroyWindow      = user32.NewProc("DestroyWindow")
	showWindow         = user32.NewProc("ShowWindow")
	setForeground      = user32.NewProc("SetForegroundWindow")
	setWindowText      = user32.NewProc("SetWindowTextW")
	getWindowText      = user32.NewProc("GetWindowTextW")
	sendMessage        = user32.NewProc("SendMessageW")
	postMessage        = user32.NewProc("PostMessageW")
	getMessage         = user32.NewProc("GetMessageW")
	translateMessage   = user32.NewProc("TranslateMessage")
	dispatchMessage    = user32.NewProc("DispatchMessageW")
	isDialogMessage    = user32.NewProc("IsDialogMessageW")
	postQuitMessage    = user32.NewProc("PostQuitMessage")
	getClientRect      = user32.NewProc("GetClientRect")
	setWindowPos       = user32.NewProc("SetWindowPos")
	enableWindow       = user32.NewProc("EnableWindow")
	setFocus           = user32.NewProc("SetFocus")
	invalidateRect     = user32.NewProc("InvalidateRect")
	loadIcon           = user32.NewProc("LoadIconW")
	loadCursor         = user32.NewProc("LoadCursorW")
	setTimer           = user32.NewProc("SetTimer")
	killTimer          = user32.NewProc("KillTimer")
	messageBox         = user32.NewProc("MessageBoxW")
	registerMessage    = user32.NewProc("RegisterWindowMessageW")
	findWindow         = user32.NewProc("FindWindowW")
	getDPI             = user32.NewProc("GetDpiForWindow")
	systemParameters   = user32.NewProc("SystemParametersInfoW")
	getSystemColor     = user32.NewProc("GetSysColor")
	createBrush        = gdi32.NewProc("CreateSolidBrush")
	deleteObject       = gdi32.NewProc("DeleteObject")
	createFont         = gdi32.NewProc("CreateFontW")
	setTextColor       = gdi32.NewProc("SetTextColor")
	setBackgroundColor = gdi32.NewProc("SetBkColor")
	fillRect           = user32.NewProc("FillRect")
	notifyIcon         = shell32.NewProc("Shell_NotifyIconW")
	shellExecute       = shell32.NewProc("ShellExecuteW")
	createMenu         = user32.NewProc("CreatePopupMenu")
	appendMenu         = user32.NewProc("AppendMenuW")
	trackMenu          = user32.NewProc("TrackPopupMenu")
	destroyMenu        = user32.NewProc("DestroyMenu")
	getCursorPos       = user32.NewProc("GetCursorPos")
)

type point struct{ X, Y int32 }
type rect struct{ Left, Top, Right, Bottom int32 }
type windowClass struct {
	Size, Style                        uint32
	Proc                               uintptr
	ClassExtra, WindowExtra            int32
	Instance, Icon, Cursor, Background uintptr
	MenuName, ClassName                *uint16
	SmallIcon                          uintptr
}
type windowMessage struct {
	Window         uintptr
	Message        uint32
	WParam, LParam uintptr
	Time           uint32
	Point          point
	Private        uint32
}
type minMaxInfo struct{ Reserved, MaxSize, MaxPosition, MinTrackSize, MaxTrackSize point }
type drawItem struct {
	Type, ID, ItemID, Action, State uint32
	Window, DC                      uintptr
	Rect                            rect
	Data                            uintptr
}
type iconData struct {
	Size                uint32
	Window              uintptr
	ID, Flags, Callback uint32
	Icon                uintptr
	Tip                 [128]uint16
	State, StateMask    uint32
	Info                [256]uint16
	Version             uint32
	Title               [64]uint16
	InfoFlags           uint32
	GUID                windows.GUID
	BalloonIcon         uintptr
}
type openFileName struct {
	Size                         uint32
	Owner, Instance              uintptr
	Filter, CustomFilter         *uint16
	MaxCustomFilter, FilterIndex uint32
	File                         *uint16
	MaxFile                      uint32
	FileTitle                    *uint16
	MaxFileTitle                 uint32
	InitialDirectory, Title      *uint16
	Flags                        uint32
	FileOffset, FileExtension    uint16
	DefaultExtension             *uint16
	CustomData, Hook             uintptr
	TemplateName                 *uint16
	Reserved                     uintptr
	Reserved2, FlagsEx           uint32
}

func wide(s string) *uint16 {
	p, err := windows.UTF16PtrFromString(s)
	if err != nil {
		p, _ = windows.UTF16PtrFromString("Invalid text")
	}
	return p
}
func textAt(hwnd uintptr) string {
	var b [8192]uint16
	getWindowText.Call(hwnd, uintptr(unsafe.Pointer(&b[0])), uintptr(len(b)))
	return windows.UTF16ToString(b[:])
}
func setText(hwnd uintptr, text string) {
	p := wide(text)
	setWindowText.Call(hwnd, uintptr(unsafe.Pointer(p)))
	runtime.KeepAlive(p)
}

// send dispatches a Win32 message with integer-only wParam and lParam values.
// Never pass Go pointers via send; use sendPointer or sendText so the Go
// garbage collector retains the pointed-to allocation until SendMessageW returns.
func send(hwnd uintptr, message uint32, wparam, lparam uintptr) uintptr {
	r, _, _ := sendMessage.Call(hwnd, uintptr(message), wparam, lparam)
	return r
}
func sendPointer[T any](hwnd uintptr, message uint32, wparam uintptr, lparam *T) uintptr {
	r, _, _ := sendMessage.Call(hwnd, uintptr(message), wparam, uintptr(unsafe.Pointer(lparam)))
	runtime.KeepAlive(lparam)
	return r
}
func sendText(hwnd uintptr, message uint32, wparam uintptr, text string) uintptr {
	return sendPointer(hwnd, message, wparam, wide(text))
}
func enabled(hwnd uintptr, yes bool) {
	v := uintptr(0)
	if yes {
		v = 1
	}
	enableWindow.Call(hwnd, v)
}

func readOnly(hwnd uintptr, yes bool) {
	style, _, _ := user32.NewProc("GetWindowLongPtrW").Call(hwnd, ^uintptr(15)) // GWL_STYLE
	if (style&0x800 != 0) == yes {                                              // ES_READONLY
		return
	}
	value := uintptr(0)
	if yes {
		value = 1
	}
	send(hwnd, 0xCF, value, 0) // EM_SETREADONLY
	invalidateRect.Call(hwnd, 0, 1)
}
func checked(hwnd uintptr) bool { return send(hwnd, 0xF0, 0, 0) == 1 }
func check(hwnd uintptr, yes bool) {
	v := uintptr(0)
	if yes {
		v = 1
	}
	send(hwnd, 0xF1, v, 0)
}
func showError(hwnd uintptr, err error) {
	if err != nil {
		msg, title := wide(err.Error()), wide("MicDrop")
		messageBox.Call(hwnd, uintptr(unsafe.Pointer(msg)), uintptr(unsafe.Pointer(title)), 0x10)
		runtime.KeepAlive(msg)
		runtime.KeepAlive(title)
	}
}
func confirm(hwnd uintptr, text string) bool {
	msg, title := wide(text), wide("MicDrop")
	r, _, _ := messageBox.Call(hwnd, uintptr(unsafe.Pointer(msg)), uintptr(unsafe.Pointer(title)), 0x24|0x100)
	runtime.KeepAlive(msg)
	runtime.KeepAlive(title)
	return r == 6
}
func shellOpen(hwnd uintptr, path string) error {
	verb, target := wide("open"), wide(path)
	r, _, _ := shellExecute.Call(hwnd, uintptr(unsafe.Pointer(verb)), uintptr(unsafe.Pointer(target)), 0, 0, 1)
	runtime.KeepAlive(verb)
	runtime.KeepAlive(target)
	if r <= 32 {
		return errors.New("Windows could not open this item")
	}
	return nil
}
func openFirewall(hwnd uintptr) error {
	directory, err := windows.GetSystemDirectory()
	if err != nil {
		return err
	}
	path := filepath.Join(directory, "control.exe")
	verb, target, args := wide("open"), wide(path), wide("firewall.cpl")
	result, _, _ := shellExecute.Call(hwnd, uintptr(unsafe.Pointer(verb)), uintptr(unsafe.Pointer(target)), uintptr(unsafe.Pointer(args)), 0, 1)
	runtime.KeepAlive(verb)
	runtime.KeepAlive(target)
	runtime.KeepAlive(args)
	if result <= 32 {
		return errors.New("Windows Firewall settings could not be opened")
	}
	return nil
}

func chooseConfig(hwnd uintptr) (string, error) {
	var path [32768]uint16
	filter := utf16.Encode([]rune("Remote configuration (*.json)\x00*.json\x00All files\x00*.*\x00\x00"))
	title := wide("Import private MicDrop remote configuration")
	options := openFileName{Owner: hwnd, Filter: &filter[0], File: &path[0], MaxFile: uint32(len(path)), Title: title, Flags: 0x1000 | 0x800 | 0x80000 | 8 | 0x2000000}
	options.Size = uint32(unsafe.Sizeof(options))
	ok, _, _ := comdlg32.NewProc("GetOpenFileNameW").Call(uintptr(unsafe.Pointer(&options)))
	runtime.KeepAlive(&options)
	runtime.KeepAlive(filter)
	runtime.KeepAlive(title)
	if ok == 0 {
		code, _, _ := comdlg32.NewProc("CommDlgExtendedError").Call()
		if code != 0 {
			return "", fmt.Errorf("Windows file picker failed (0x%x)", code)
		}
		return "", nil
	}
	return windows.UTF16ToString(path[:]), nil
}
func copyText(hwnd uintptr, text string) error {
	data, err := windows.UTF16FromString(text)
	if err != nil {
		return err
	}
	memory, _, _ := kernel32.NewProc("GlobalAlloc").Call(2, uintptr(len(data)*2))
	if memory == 0 {
		return errors.New("cannot allocate clipboard memory")
	}
	owned := true
	defer func() {
		if owned {
			kernel32.NewProc("GlobalFree").Call(memory)
		}
	}()
	ptr, _, _ := kernel32.NewProc("GlobalLock").Call(memory)
	if ptr == 0 {
		return errors.New("cannot lock clipboard memory")
	}
	moveMemory.Call(ptr, uintptr(unsafe.Pointer(&data[0])), uintptr(len(data)*2))
	runtime.KeepAlive(data)
	kernel32.NewProc("GlobalUnlock").Call(memory)
	ok, _, _ := user32.NewProc("OpenClipboard").Call(hwnd)
	if ok == 0 {
		return errors.New("clipboard is busy; try again")
	}
	defer user32.NewProc("CloseClipboard").Call()
	ok, _, _ = user32.NewProc("EmptyClipboard").Call()
	if ok == 0 {
		return errors.New("cannot clear clipboard")
	}
	ok, _, _ = user32.NewProc("SetClipboardData").Call(13, memory)
	if ok == 0 {
		return errors.New("cannot copy pairing link")
	}
	owned = false
	return nil
}
func replaceSettings(from, to string) error {
	return windows.MoveFileEx(wide(from), wide(to), windows.MOVEFILE_REPLACE_EXISTING|windows.MOVEFILE_WRITE_THROUGH)
}

const startupKey = `Software\Microsoft\Windows\CurrentVersion\Run`

func startupCommand() (string, error) {
	path, err := os.Executable()
	if err != nil {
		return "", err
	}
	path, err = filepath.Abs(path)
	if err != nil {
		return "", err
	}
	command := syscall.EscapeArg(path) + " desktop --background"
	if len(utf16.Encode([]rune(command))) > 260 {
		return "", errors.New("the app path is too long for Windows startup; move the complete application folder to a shorter path")
	}
	return command, nil
}
func startupEnabled() (bool, error) {
	key, err := registry.OpenKey(registry.CURRENT_USER, startupKey, registry.QUERY_VALUE)
	if errors.Is(err, syscall.ENOENT) {
		return false, nil
	}
	if err != nil {
		return false, err
	}
	defer key.Close()
	value, _, err := key.GetStringValue("MicDrop")
	if errors.Is(err, syscall.ENOENT) {
		return false, nil
	}
	if err != nil {
		return false, err
	}
	current, err := startupCommand()
	return value == current, err
}
func setStartup(yes bool) error {
	command, err := startupCommand()
	if yes && err != nil {
		return err
	}
	key, _, err := registry.CreateKey(registry.CURRENT_USER, startupKey, registry.SET_VALUE)
	if err != nil {
		return err
	}
	defer key.Close()
	if yes {
		return key.SetStringValue("MicDrop", command)
	}
	err = key.DeleteValue("MicDrop")
	if errors.Is(err, syscall.ENOENT) {
		return nil
	}
	return err
}
