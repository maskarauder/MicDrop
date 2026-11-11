//go:build windows

package desktop

import (
	"errors"
	"fmt"
	"os"
	"path/filepath"
	"runtime"
	"strconv"
	"strings"
	"time"
	"unsafe"

	"github.com/maskarauder/MicDrop/internal/version"
	qrcode "github.com/skip2/go-qrcode"
	"golang.org/x/sys/windows"
)

const (
	wmTray  = 0x8001
	wmShow  = 0x8002
	idStart = 100 + iota
	idStop
	idAudio
	idConnection
	idPhones
	idSave
	idLogs
	idExit
	idCapture
	idMicrophone
	idRefreshAudio
	idCableHelp
	idNetwork
	idRefreshNetwork
	idPort
	idRemote
	idRemoteStatus
	idImport
	idForget
	idStartup
	idNotifications
	idPhoneList
	idRemove
	idPair
	idPending
	idApprove
	idReject
	idQR
	idCopy
	idExpiry
	idStatus
	idMessage
	idTitle
	idFirewall
	idOptions
	idSaveLogs
	idLogRetention
	idDeviceCount
	idDeviceList
	idDeviceMetrics
	idDeviceSettings
	idPhoneSettingsTitle
	idPhoneSettingsGroup
	idPhoneSettingsList
	idPhoneFieldLabel
	idPhoneFieldBool
	idPhoneFieldInt
	idPhoneFieldChoice
	idPhoneFieldEffect
	idPhoneSettingsStatus
	idPhoneSettingsApply
	idPhoneSettingsReload
	idPhoneSettingsBack
)

type control struct {
	handle           uintptr
	class            string
	page, x, y, w, h int
}
type uiResult struct {
	devices  []AudioDevice
	networks []Network
	remote   string
	err      error
	refresh  bool
	message  string
}
type desktopWindow struct {
	hwnd, instance, icon                                    uintptr
	controls                                                map[int]control
	backend                                                 Backend
	controller                                              *Controller
	settings                                                Settings
	directory                                               string
	page, dpi                                               int
	font, titleFont, backgroundBrush, panelBrush, goldBrush uintptr
	background, panel, foreground, gold                     uint32
	highContrast                                            bool
	palette                                                 controlPalette
	taskbarMessage                                          uint32
	tray                                                    bool
	trayStatus                                              string
	busy, closing, destroyed, modal                         bool
	jobs                                                    chan uiResult
	closed                                                  chan struct{}
	devices                                                 []AudioDevice
	networks                                                []Network
	captureIDs, microphoneIDs                               []string
	phoneKeys                                               []string
	phoneDisplay                                            string
	deviceKeys                                              []string
	deviceDisplay                                           string
	phoneEditor                                             *phoneSettingsEditor
	currentLink                                             string
	qr                                                      [][]bool
	lastRevision                                            uint64
	labelID                                                 int
}

// Windows dispatches on the locked UI thread. A single desktop per user/session
// owns this pointer; callbacks from the host only update Controller's mutex state.
var activeWindow *desktopWindow
var desktopWndProc = windows.NewCallback(desktopProcedure)

func ShowError(err error) { showError(0, err) }

func Run(backend Backend, directory string, background bool) error {
	if runtime.GOARCH != "amd64" {
		return errors.New("MicDrop desktop requires Windows x64")
	}
	token := windows.GetCurrentProcessToken()
	user, err := token.GetTokenUser()
	if err != nil {
		return err
	}
	className := "MicDrop.Desktop." + user.User.Sid.String()
	return runWindow(backend, directory, background, className)
}

func runWindow(backend Backend, directory string, background bool, className string) error {
	runtime.LockOSThread()
	defer runtime.UnlockOSThread()
	mutex, err := windows.CreateMutex(nil, false, wide(`Local\`+className))
	if mutex != 0 {
		defer windows.CloseHandle(mutex)
	}
	if errors.Is(err, windows.ERROR_ALREADY_EXISTS) {
		hwnd, _, _ := findWindow.Call(uintptr(unsafe.Pointer(wide(className))), 0)
		if hwnd != 0 {
			postMessage.Call(hwnd, wmShow, 0, 0)
			setForeground.Call(hwnd)
		}
		return nil
	}
	if err != nil {
		return err
	}
	settings, err := LoadSettings(directory)
	if err != nil {
		return err
	} // Never overwrite corrupt/newer settings.
	user32.NewProc("SetProcessDpiAwarenessContext").Call(^uintptr(3)) // Per-monitor V2; manifest normally sets this.
	var instance windows.Handle
	if err := windows.GetModuleHandleEx(2, nil, &instance); err != nil {
		return err
	}
	icon, _, _ := loadIcon.Call(0, 32512) // Standard Windows application icon; branding placeholder.
	cursor, _, _ := loadCursor.Call(0, 32512)
	wc := windowClass{Proc: desktopWndProc, Instance: uintptr(instance), Icon: icon, SmallIcon: icon, Cursor: cursor, ClassName: wide(className)}
	wc.Size = uint32(unsafe.Sizeof(wc))
	atom, _, callErr := registerClass.Call(uintptr(unsafe.Pointer(&wc)))
	if atom == 0 {
		return fmt.Errorf("register desktop window: %w", callErr)
	}
	defer unregisterClass.Call(uintptr(unsafe.Pointer(wc.ClassName)), uintptr(instance))
	u := &desktopWindow{instance: uintptr(instance), icon: icon, backend: backend, controller: NewController(backend), settings: settings, directory: directory, controls: make(map[int]control), dpi: 96, jobs: make(chan uiResult, 1), closed: make(chan struct{}), labelID: 1000}
	activeWindow = u
	defer func() { activeWindow = nil; close(u.closed) }()
	u.colors()
	defer u.releaseGraphics()
	hwnd, _, callErr := createWindow.Call(0x10000, uintptr(unsafe.Pointer(wc.ClassName)), uintptr(unsafe.Pointer(wide("MicDrop "+version.Current().Version))), 0xCF0000|0x02000000, 0x80000000, 0x80000000, 860, 700, 0, 0, uintptr(instance), 0)
	if hwnd == 0 {
		return fmt.Errorf("create desktop window: %w", callErr)
	}
	u.hwnd = hwnd
	u.updateControlTheme()
	defer destroyWindow.Call(hwnd)
	dpi, _, _ := getDPI.Call(hwnd)
	if dpi != 0 {
		u.dpi = int(dpi)
	}
	u.fonts()
	if err := u.build(); err != nil {
		return err
	}
	message, _, _ := registerMessage.Call(uintptr(unsafe.Pointer(wide("TaskbarCreated"))))
	u.taskbarMessage = uint32(message)
	var work rect
	systemParameters.Call(0x30, 0, uintptr(unsafe.Pointer(&work)), 0)
	width, height := u.scale(860), u.scale(700)
	if work.Right > work.Left {
		width = min(width, int(work.Right-work.Left)-24)
		height = min(height, int(work.Bottom-work.Top)-24)
	}
	setWindowPos.Call(hwnd, 0, 0, 0, uintptr(width), uintptr(height), 0x16)
	u.layout()
	u.selectPage(0)
	u.trayUpdate("Stopped")
	defer u.removeTray()
	showWindow.Call(hwnd, 1)
	setTimer.Call(hwnd, 1, 250, 0)
	defer killTimer.Call(hwnd, 1)
	u.refresh()
	if background {
		if u.tray {
			showWindow.Call(hwnd, 0)
		}
		// Startup is explicitly opted in. Existing approved phones still authorize
		// each session; neither startup nor pairing opens capture by itself.
		if err := u.controller.Start(settings); err != nil {
			u.show()
			u.showErr(err)
		}
	}
	for {
		var message windowMessage
		result, _, err := getMessage.Call(uintptr(unsafe.Pointer(&message)), 0, 0, 0)
		if int32(result) == -1 {
			<-u.controller.Stop()
			return fmt.Errorf("Windows message loop: %w", err)
		}
		if result == 0 {
			break
		}
		handled, _, _ := isDialogMessage.Call(hwnd, uintptr(unsafe.Pointer(&message)))
		if handled == 0 {
			translateMessage.Call(uintptr(unsafe.Pointer(&message)))
			dispatchMessage.Call(uintptr(unsafe.Pointer(&message)))
		}
	}
	<-u.controller.Stop()
	return nil
}
func (u *desktopWindow) scale(n int) int { return n * u.dpi / 96 }
func (u *desktopWindow) releaseGraphics() {
	for _, object := range []uintptr{u.font, u.titleFont, u.backgroundBrush, u.panelBrush, u.goldBrush} {
		if object != 0 {
			deleteObject.Call(object)
		}
	}
}
func (u *desktopWindow) colors() {
	u.background = 0x312820
	u.panel = 0x41352A
	u.foreground = 0xF2EEE9
	u.gold = 0x45ACD4
	var contrast struct {
		Size, Flags uint32
		Scheme      *uint16
	}
	contrast.Size = uint32(unsafe.Sizeof(contrast))
	systemParameters.Call(0x42, uintptr(contrast.Size), uintptr(unsafe.Pointer(&contrast)), 0)
	u.highContrast = contrast.Flags&1 != 0
	if u.highContrast {
		bg, _, _ := getSystemColor.Call(5)
		fg, _, _ := getSystemColor.Call(8)
		accent, _, _ := getSystemColor.Call(13)
		u.background = uint32(bg)
		u.panel = uint32(bg)
		u.foreground = uint32(fg)
		u.gold = uint32(accent)
	}
	for _, p := range []*uintptr{&u.backgroundBrush, &u.panelBrush, &u.goldBrush} {
		if *p != 0 {
			deleteObject.Call(*p)
		}
	}
	u.backgroundBrush, _, _ = createBrush.Call(uintptr(u.background))
	u.panelBrush, _, _ = createBrush.Call(uintptr(u.panel))
	u.goldBrush, _, _ = createBrush.Call(uintptr(u.gold))
	u.updateControlTheme()
}
func (u *desktopWindow) fonts() {
	old, oldTitle := u.font, u.titleFont
	u.font, _, _ = createFont.Call(uintptr(-int32(u.scale(15))), 0, 0, 0, 400, 0, 0, 0, 1, 0, 0, 5, 0, uintptr(unsafe.Pointer(wide("Segoe UI"))))
	u.titleFont, _, _ = createFont.Call(uintptr(-int32(u.scale(25))), 0, 0, 0, 600, 0, 0, 0, 1, 0, 0, 5, 0, uintptr(unsafe.Pointer(wide("Segoe UI"))))
	for id, c := range u.controls {
		font := u.font
		if id == idTitle {
			font = u.titleFont
		}
		send(c.handle, 0x30, font, 1)
		u.resizeControl(c.handle, c.class)
	}
	if old != 0 {
		deleteObject.Call(old)
	}
	if oldTitle != 0 {
		deleteObject.Call(oldTitle)
	}
}
func (u *desktopWindow) add(id int, class, title string, style uintptr, page, x, y, w, h int) error {
	hwnd, _, err := createWindow.Call(0, uintptr(unsafe.Pointer(wide(class))), uintptr(unsafe.Pointer(wide(title))), 0x40000000|0x10000000|style, 0, 0, 0, 0, u.hwnd, uintptr(id), u.instance, 0)
	if hwnd == 0 {
		return fmt.Errorf("create %s control: %w", class, err)
	}
	u.controls[id] = control{hwnd, class, page, x, y, w, h}
	if err := u.themeControl(hwnd, class, style); err != nil {
		return err
	}
	font := u.font
	if id == idTitle {
		font = u.titleFont
	}
	send(hwnd, 0x30, font, 0)
	u.resizeControl(hwnd, class)
	return nil
}
func (u *desktopWindow) build() error {
	var first error
	add := func(id int, class, title string, style uintptr, page, x, y, w, h int) {
		if first == nil {
			first = u.add(id, class, title, style, page, x, y, w, h)
		}
	}
	label := func(text string, page, x, y, w, h int) {
		u.labelID++
		add(u.labelID, "STATIC", text, 0, page, x, y, w, h)
	}
	button := func(id int, text string, page, x, y, w int) { add(id, "BUTTON", text, 0x10000|0xB, page, x, y, w, 30) }
	combo := func(id, page, x, y, w int) {
		add(id, "COMBOBOX", "", 0x10000|0x200000|3|0x10|0x200, page, x, y, w, 220)
	}
	add(idTitle, "STATIC", "MicDrop", 0, -1, 24, 18, 150, 36)
	add(idStatus, "STATIC", "Stopped", 0, -1, 24, 59, 142, 66)
	add(idDeviceCount, "STATIC", "0 devices connected", 0, -1, 180, 14, -276, 22)
	add(idDeviceList, "LISTBOX", "", 0x10000|0x800000|0x200000|1|0x10|0x40, -1, 180, 40, -276, 52)
	add(idDeviceMetrics, "STATIC", "Select a phone to view its connection.", 0, -1, 180, 96, -24, 36)
	button(idStart, "&Start host", -1, -248, 28, 104)
	button(idStop, "S&top host", -1, -132, 28, 108)
	button(idDeviceSettings, "Device settings…", -1, -248, 70, 224)
	button(idAudio, "&Audio", -1, 24, 106, 112)
	button(idConnection, "&Connection", -1, 148, 106, 132)
	button(idPhones, "&Phones", -1, 292, 106, 112)
	button(idOptions, "&Options", -1, 416, 106, 112)
	add(idMessage, "STATIC", "Choose your audio devices and LAN adapter, then save and start.", 0, -1, 24, -84, -24, 38)
	button(idSave, "&Save settings", -1, 24, -40, 136)
	button(idLogs, "Open &logs", -1, 172, -40, 120)
	button(idExit, "E&xit", -1, -120, -40, 96)
	label("Audio routing", 0, 24, 162, -24, 24)
	label("&Desktop audio source", 0, 24, 204, -24, 22)
	combo(idCapture, 0, 24, 232, -24)
	label("The default output is selected when each phone session starts.", 0, 24, 269, -24, 24)
	label("Phone &microphone destination", 0, 24, 314, -24, 22)
	combo(idMicrophone, 0, 24, 342, -24)
	label("Choose the virtual cable's playback endpoint (for example CABLE Input).\r\nIn Discord or another receiving app, choose the cable's recording endpoint (CABLE Output).", 0, 24, 380, -24, 56)
	button(idRefreshAudio, "&Refresh devices", 0, 24, 454, 150)
	button(idCableHelp, "Cable setup…", 0, 186, 454, 140)
	label("&LAN adapter", 1, 24, 162, -24, 22)
	combo(idNetwork, 1, 24, 190, -198)
	button(idRefreshNetwork, "Refresh &network", 1, -182, 190, 158)
	label("Control &port", 1, 24, 238, 120, 22)
	add(idPort, "EDIT", strconv.Itoa(u.settings.Port), 0x10000|0x800000|0x2000, 1, 24, 266, 110, 28)
	add(idRemote, "BUTTON", "Enable &remote connections", 0x10000|3, 1, 166, 263, -24, 30)
	add(idRemoteStatus, "STATIC", "Reading remote configuration…", 0, 1, 24, 312, -24, 36)
	button(idImport, "&Import remote config…", 1, 24, 358, 198)
	button(idForget, "Forget remote config", 1, 234, 358, 192)
	add(idStartup, "BUTTON", "Start host when I sign in to Windows", 0x10000|3, 3, 24, 180, -24, 28)
	add(idNotifications, "BUTTON", "Show connection and pairing notifications", 0x10000|3, 3, 24, 222, -24, 28)
	add(idSaveLogs, "BUTTON", "Save connection logs", 0x10000|3, 3, 24, 282, -24, 28)
	label("Keep newest &connection logs (0 keeps all)", 3, 24, 326, -24, 24)
	add(idLogRetention, "EDIT", strconv.Itoa(u.settings.LogRetention), 0x10000|0x800000|0x2000, 3, 24, 358, 110, 28)
	label("A positive limit keeps the newest logs and deletes the oldest. Active logs are kept.\r\nTurning logging off keeps existing files. Save while the host is stopped.", 3, 24, 406, -24, 60)
	button(idFirewall, "Windows Firewall…", 1, 24, 496, 192)
	label("Approved phones", 2, 24, 162, -324, 24)
	add(idPhoneList, "LISTBOX", "", 0x10000|0x800000|0x200000|1|0x10|0x40, 2, 24, 192, -324, 130)
	button(idRemove, "Remove selected phone", 2, 24, 334, 220)
	button(idPair, "&Pair a phone", 2, 24, 376, 160)
	add(idPending, "EDIT", "No pending approval.", 0x10000|0x800000|0x200000|4|0x800|0x40, 2, 24, 418, -324, 60)
	button(idApprove, "&Approve", 2, 24, 488, 110)
	button(idReject, "&Reject", 2, 146, 488, 110)
	label("Private pairing invitation", 2, -284, 162, 260, 24)
	add(idQR, "STATIC", "", 0xD, 2, -284, 192, 260, 260)
	button(idCopy, "Copy pairing link", 2, -284, 464, 260)
	add(idExpiry, "STATIC", "Pairing is closed.", 0, 2, -284, 502, 260, 24)
	add(idPhoneSettingsTitle, "STATIC", "Phone settings", 0, 4, 24, 162, -24, 26)
	combo(idPhoneSettingsGroup, 4, 24, 200, 348)
	button(idPhoneSettingsBack, "Back", 4, -142, 200, 118)
	add(idPhoneSettingsList, "LISTBOX", "", 0x10000|0x800000|0x200000|1|0x10|0x40, 4, 24, 240, 348, 256)
	add(idPhoneFieldLabel, "STATIC", "Select a setting.", 0, 4, 396, 240, -24, 64)
	add(idPhoneFieldBool, "BUTTON", "Enabled", 0x10000|3, 4, 396, 312, -24, 30)
	add(idPhoneFieldInt, "EDIT", "", 0x10000|0x800000, 4, 396, 312, 140, 28)
	combo(idPhoneFieldChoice, 4, 396, 312, -24)
	add(idPhoneFieldEffect, "STATIC", "", 0, 4, 396, 354, -24, 52)
	button(idPhoneSettingsApply, "Apply setting", 4, 396, 414, 158)
	button(idPhoneSettingsReload, "Reload", 4, 566, 414, 118)
	add(idPhoneSettingsStatus, "STATIC", "", 0, 4, 396, 458, -24, 72)
	if first != nil {
		return first
	}
	check(u.controls[idRemote].handle, u.settings.Remote)
	check(u.controls[idNotifications].handle, u.settings.Notifications)
	check(u.controls[idSaveLogs].handle, u.settings.SaveLogs)
	startup, err := startupEnabled()
	if err != nil {
		setText(u.controls[idMessage].handle, "Windows startup preference could not be read.")
	}
	check(u.controls[idStartup].handle, startup)
	u.tick()
	return nil
}
func (u *desktopWindow) layout() {
	if u.hwnd == 0 {
		return
	}
	var area rect
	getClientRect.Call(u.hwnd, uintptr(unsafe.Pointer(&area)))
	width, height := int(area.Right)*96/u.dpi, int(area.Bottom)*96/u.dpi
	for _, c := range u.controls {
		x, y, w, h := c.x, c.y, c.w, c.h
		if y >= 106 {
			y += 46 // Persistent device header above every page.
		}
		if x < 0 {
			x = width + x
		}
		if y < 0 {
			y = height + y
		}
		if w < 0 {
			w = width - x + w
		}
		setWindowPos.Call(c.handle, 0, uintptr(u.scale(x)), uintptr(u.scale(y)), uintptr(u.scale(max(w, 1))), uintptr(u.scale(h)), 0x14)
	}
	invalidateRect.Call(u.hwnd, 0, 1)
}
func (u *desktopWindow) selectPage(page int) {
	u.page = page
	for _, c := range u.controls {
		mode := uintptr(0)
		if c.page < 0 || c.page == page {
			mode = 5
		}
		showWindow.Call(c.handle, mode)
	}
	for i, id := range []int{idAudio, idConnection, idPhones, idOptions} {
		text := []string{"&Audio", "&Connection", "&Phones", "&Options"}[i]
		if i == page {
			text = "• " + text
		}
		setText(u.controls[id].handle, text)
	}
	u.phoneEditorVisibility()
}
func (u *desktopWindow) show() { showWindow.Call(u.hwnd, 9); setForeground.Call(u.hwnd) }
func (u *desktopWindow) preferences() (Settings, error) {
	s := u.settings
	selection := int(int32(send(u.controls[idNetwork].handle, 0x147, 0, 0)))
	if selection >= 0 && selection < len(u.networks) {
		s.Interface = u.networks[selection].Interface
		s.AddressHint = u.networks[selection].Address
	}
	selection = int(int32(send(u.controls[idCapture].handle, 0x147, 0, 0)))
	if selection >= 0 && selection < len(u.captureIDs) {
		s.CaptureDevice = u.captureIDs[selection]
	}
	selection = int(int32(send(u.controls[idMicrophone].handle, 0x147, 0, 0)))
	if selection >= 0 && selection < len(u.microphoneIDs) {
		s.MicrophoneDevice = u.microphoneIDs[selection]
	}
	port, err := strconv.Atoi(strings.TrimSpace(textAt(u.controls[idPort].handle)))
	if err != nil {
		return s, errors.New("enter a LAN port between 1 and 65535")
	}
	s.Port = port
	s.Remote = checked(u.controls[idRemote].handle)
	s.Notifications = checked(u.controls[idNotifications].handle)
	s.SaveLogs = checked(u.controls[idSaveLogs].handle)
	retention, err := strconv.Atoi(strings.TrimSpace(textAt(u.controls[idLogRetention].handle)))
	if err != nil {
		return s, errors.New("enter a connection log limit from 0 to 10000; 0 keeps all")
	}
	s.LogRetention = retention
	return s, s.Validate()
}
func (u *desktopWindow) save() error {
	s, err := u.preferences()
	if err != nil {
		return err
	}
	if err = SaveSettings(u.directory, s); err != nil {
		return err
	}
	u.settings = s
	setText(u.controls[idMessage].handle, "Settings saved. Existing paired phones are unchanged.")
	return nil
}
func (u *desktopWindow) work(fn func() uiResult) {
	if u.busy || u.closing {
		return
	}
	u.busy = true
	u.tick()
	go func() {
		result := fn()
		select {
		case u.jobs <- result:
		case <-u.closed:
		}
	}()
}
func (u *desktopWindow) refresh() {
	if u.busy {
		return
	}
	// Retain the user's unsaved choices while refreshing device inventories.
	if s, err := u.preferences(); err == nil {
		u.settings = s
	}
	u.work(func() uiResult {
		devices, err := u.backend.Devices()
		networks, netErr := Networks()
		if err == nil {
			err = netErr
		}
		remote, _ := u.backend.RemoteStatus()
		return uiResult{devices: devices, networks: networks, remote: remote, err: err, refresh: true}
	})
}
func comboItems(hwnd uintptr, labels []string, selected int) {
	send(hwnd, 0x14B, 0, 0)
	for _, label := range labels {
		send(hwnd, 0x143, 0, uintptr(unsafe.Pointer(wide(label))))
	}
	if selected >= 0 {
		send(hwnd, 0x14E, uintptr(selected), 0)
	}
}
func (u *desktopWindow) inventory(r uiResult) {
	u.devices = r.devices
	for _, input := range []struct {
		id           int
		saved, first string
	}{{idCapture, u.settings.CaptureDevice, "Default Windows output"}, {idMicrophone, u.settings.MicrophoneDevice, "Disabled — desktop playback only"}} {
		ids := []string{""}
		labels := []string{input.first}
		selection := 0
		found := input.saved == ""
		for _, device := range r.devices {
			ids = append(ids, device.ID)
			labels = append(labels, device.Name)
			if device.ID == input.saved {
				selection = len(ids) - 1
				found = true
			}
		}
		if !found {
			ids = append(ids, input.saved)
			labels = append(labels, "Saved device unavailable — select a replacement")
			selection = len(ids) - 1
		}
		comboItems(u.controls[input.id].handle, labels, selection)
		if input.id == idCapture {
			u.captureIDs = ids
		} else {
			u.microphoneIDs = ids
		}
	}
	u.networks = append([]Network{{}}, r.networks...)
	labels := []string{"Choose your home LAN adapter"}
	selection := 0
	found := u.settings.Interface == ""
	resolved, resolveErr := ResolveNetwork(u.settings, r.networks)
	for i, n := range r.networks {
		labels = append(labels, n.Label())
		if resolveErr == nil && n == resolved {
			selection = i + 1
			found = true
		}
	}
	if !found {
		u.networks = append(u.networks, Network{u.settings.Interface, u.settings.AddressHint})
		labels = append(labels, "Saved adapter unavailable — "+u.settings.Interface)
		selection = len(labels) - 1
	}
	comboItems(u.controls[idNetwork].handle, labels, selection)
	setText(u.controls[idRemoteStatus].handle, r.remote)
}
func (u *desktopWindow) showErr(err error) {
	if err == nil || u.closing || u.destroyed || u.modal {
		return
	}
	u.modal = true
	defer func() { u.modal = false }()
	showError(u.hwnd, err)
}
func (u *desktopWindow) askConfirm(text string) bool {
	if u.closing || u.destroyed || u.modal {
		return false
	}
	u.modal = true
	defer func() { u.modal = false }()
	return confirm(u.hwnd, text)
}
func (u *desktopWindow) pickConfig() (string, error) {
	if u.closing || u.destroyed || u.modal {
		return "", nil
	}
	u.modal = true
	defer func() { u.modal = false }()
	return chooseConfig(u.hwnd)
}
func (u *desktopWindow) tick() {
	if u.hwnd == 0 || u.destroyed || len(u.controls) == 0 {
		return
	}
	select {
	case r := <-u.jobs:
		u.busy = false
		if r.refresh {
			u.inventory(r)
		} else {
			remote, _ := u.backend.RemoteStatus()
			setText(u.controls[idRemoteStatus].handle, remote)
		}
		if r.err != nil {
			if u.modal && !u.closing {
				setText(u.controls[idMessage].handle, r.err.Error())
			} else {
				u.showErr(r.err)
			}
		} else if r.message != "" {
			setText(u.controls[idMessage].handle, r.message)
		}
	default:
	}
	state := u.controller.Snapshot()
	u.renderConnections(state)
	stopped, ready := state.Phase == "stopped", state.Phase == "ready"
	if u.closing && stopped && !u.busy && !u.modal {
		destroyWindow.Call(u.hwnd)
		return
	}
	editable := stopped && !u.busy && !u.closing
	for _, id := range []int{idStart, idSave, idCapture, idMicrophone, idRefreshAudio, idNetwork, idRefreshNetwork, idRemote, idImport, idForget, idNotifications, idSaveLogs} {
		enabled(u.controls[id].handle, editable)
	}
	// Read-only preserves selectable, flat text while still preventing edits
	// during a session; a disabled native EDIT forces Windows' gray text color.
	readOnly(u.controls[idPort].handle, !editable)
	readOnly(u.controls[idLogRetention].handle, !editable || !checked(u.controls[idSaveLogs].handle))
	enabled(u.controls[idStop].handle, !stopped && state.Phase != "stopping" && !u.closing)
	enabled(u.controls[idStartup].handle, !u.closing)
	for _, id := range []int{idPair, idRemove, idPhoneList} {
		enabled(u.controls[id].handle, ready && !u.closing)
	}
	for _, id := range []int{idApprove, idReject} {
		enabled(u.controls[id].handle, ready && state.Pending.ID != "" && !u.closing)
	}
	enabled(u.controls[idCopy].handle, state.Link != "" && !u.closing)
	if textAt(u.controls[idStatus].handle) != state.Status {
		setText(u.controls[idStatus].handle, state.Status)
	}
	if state.Revision != u.lastRevision {
		u.lastRevision = state.Revision
		if state.Message != "" {
			setText(u.controls[idMessage].handle, state.Message)
		}
		if stopped && state.Failed {
			u.show()
		}
		var phoneDisplay strings.Builder
		for _, phone := range state.Phones {
			fmt.Fprintf(&phoneDisplay, "%s\x00%s\n", phone.Name, phone.Key)
		}
		if phoneDisplay.String() != u.phoneDisplay {
			selected := ""
			idx := int(int32(send(u.controls[idPhoneList].handle, 0x188, 0, 0)))
			if idx >= 0 && idx < len(u.phoneKeys) {
				selected = u.phoneKeys[idx]
			}
			u.phoneDisplay = phoneDisplay.String()
			u.phoneKeys = nil
			send(u.controls[idPhoneList].handle, 0x184, 0, 0)
			for i, phone := range state.Phones {
				u.phoneKeys = append(u.phoneKeys, phone.Key)
				label := phone.Name + "  ·  " + phone.Key[:min(12, len(phone.Key))]
				send(u.controls[idPhoneList].handle, 0x180, 0, uintptr(unsafe.Pointer(wide(label))))
				if phone.Key == selected {
					send(u.controls[idPhoneList].handle, 0x186, uintptr(i), 0)
				}
			}
		}
	}
	pending := "No pending approval."
	if state.Pending.ID != "" {
		pending = "Unverified name: " + state.Pending.Name + "\r\nRequest ID: " + state.Pending.ID + "\r\nPhone key: " + state.Pending.Key
	}
	if textAt(u.controls[idPending].handle) != pending {
		setText(u.controls[idPending].handle, pending)
	}
	if state.Link != u.currentLink {
		u.currentLink = state.Link
		u.qr = nil
		if state.Link != "" {
			code, err := qrcode.New(state.Link, qrcode.Low)
			if err == nil {
				u.qr = code.Bitmap()
			}
		}
		invalidateRect.Call(u.controls[idQR].handle, 0, 1)
	}
	expiry := "Pairing is closed."
	if state.Link != "" {
		expiry = "Private · expires in " + strconv.Itoa(max(0, int(time.Until(state.Expires).Seconds()))) + " seconds"
	}
	if textAt(u.controls[idExpiry].handle) != expiry {
		setText(u.controls[idExpiry].handle, expiry)
	}
	u.trayUpdate(state.Status)
	for _, notice := range u.controller.Notices() {
		if u.settings.Notifications {
			u.notify(notice)
		}
	}
}
func (u *desktopWindow) action(id int) {
	state := u.controller.Snapshot()
	if u.closing || u.destroyed || (u.modal && id != idStop && id != idExit) {
		return
	}
	switch id {
	case idAudio:
		u.selectPage(0)
	case idConnection:
		u.selectPage(1)
	case idPhones:
		u.selectPage(2)
	case idOptions:
		u.selectPage(3)
	case idDeviceSettings:
		u.openPhoneSettings()
	case idPhoneSettingsBack:
		u.selectPage(2)
	case idPhoneSettingsApply:
		u.applyPhoneSetting()
	case idPhoneSettingsReload:
		u.reloadPhoneSettings()
	case idStart:
		if u.busy || state.Phase != "stopped" {
			return
		}
		if err := u.save(); err != nil {
			u.showErr(err)
			return
		}
		if err := u.controller.Start(u.settings); err != nil {
			u.showErr(err)
		}
	case idStop:
		u.controller.Stop()
	case idSave:
		if !u.busy && state.Phase == "stopped" {
			u.showErr(u.save())
		}
	case idRefreshAudio, idRefreshNetwork:
		if state.Phase == "stopped" {
			u.refresh()
		}
	case idImport:
		if state.Phase != "stopped" || u.busy {
			return
		}
		path, err := u.pickConfig()
		if err != nil {
			u.showErr(err)
			return
		}
		if path == "" || u.closing || u.destroyed || u.busy || u.controller.Snapshot().Phase != "stopped" {
			return
		}
		u.work(func() uiResult {
			return uiResult{err: u.backend.ImportRemote(path), message: "Remote configuration imported. Enable remote connections and save to use it."}
		})
	case idForget:
		if state.Phase != "stopped" || u.busy {
			return
		}
		if u.askConfirm("Remove this PC's remote configuration? LAN pairing is kept. Remote access will need another configuration import.") {
			if u.closing || u.destroyed || u.busy || u.controller.Snapshot().Phase != "stopped" {
				return
			}
			u.work(func() uiResult {
				return uiResult{err: u.backend.ForgetRemote(), message: "Remote configuration removed. Disable remote connections to use LAN only."}
			})
		}
	case idStartup:
		yes := checked(u.controls[idStartup].handle)
		if yes {
			if state.Phase != "stopped" || u.busy {
				u.showErr(errors.New("stop the host and save its settings before enabling startup"))
				check(u.controls[idStartup].handle, false)
				return
			}
			if err := u.save(); err != nil {
				u.showErr(err)
				check(u.controls[idStartup].handle, false)
				return
			}
			networks, err := Networks()
			if err == nil {
				_, err = ResolveNetwork(u.settings, networks)
			}
			if err != nil {
				u.showErr(err)
				check(u.controls[idStartup].handle, false)
				return
			}
		}
		if err := setStartup(yes); err != nil {
			u.showErr(err)
			actual, _ := startupEnabled()
			check(u.controls[idStartup].handle, actual)
		}
	case idPair:
		u.showErr(u.controller.Command(Command{Action: "pair"}))
	case idApprove, idReject:
		pending := state.Pending
		if pending.ID == "" {
			return
		}
		action := "reject"
		if id == idApprove {
			if !u.askConfirm("Approve this phone only if its request ID matches:\r\n\r\n" + pending.ID + "\r\n\r\nUnverified name: " + pending.Name + "\r\nPhone key: " + pending.Key) {
				return
			}
			action = "approve"
		}
		u.showErr(u.controller.Command(Command{Action: action, Value: pending.ID}))
	case idRemove:
		idx := int(int32(send(u.controls[idPhoneList].handle, 0x188, 0, 0)))
		if idx < 0 || idx >= len(u.phoneKeys) {
			u.showErr(errors.New("select a paired phone first"))
			return
		}
		key := u.phoneKeys[idx]
		if u.askConfirm("Remove this phone and stop its active stream?\r\n\r\nPhone key: " + key) {
			u.showErr(u.controller.Command(Command{Action: "revoke", Value: key}))
		}
	case idCopy:
		if state.Link != "" {
			u.showErr(copyText(u.hwnd, state.Link))
		}
	case idLogs:
		directory := filepath.Join(u.directory, "logs")
		if err := os.MkdirAll(directory, 0700); err != nil {
			u.showErr(err)
		} else {
			u.showErr(shellOpen(u.hwnd, directory))
		}
	case idFirewall:
		u.showErr(openFirewall(u.hwnd))
	case idCableHelp:
		if !u.modal {
			u.modal = true
			messageBox.Call(u.hwnd, uintptr(unsafe.Pointer(wide("Install a virtual audio cable separately, then restart Windows if its installer requests it.\r\n\r\nChoose its playback endpoint here (usually CABLE Input). In Discord or your recording app, choose its recording endpoint (usually CABLE Output). Keep Windows 'Listen to this device' off.\r\n\r\nDesktop playback works with microphone return disabled. MicDrop does not install or bundle a driver."))), uintptr(unsafe.Pointer(wide("Microphone return setup"))), 0x40)
			u.modal = false
		}
	case idExit:
		u.closing = true
		u.controller.Stop()
	}
	u.tick()
}
func (u *desktopWindow) trayData() iconData {
	d := iconData{Window: u.hwnd, ID: 1, Flags: 1 | 2 | 4, Callback: wmTray, Icon: u.icon}
	d.Size = uint32(unsafe.Sizeof(d))
	copy(d.Tip[:], utf16Text("MicDrop · "+u.trayStatus))
	return d
}
func utf16Text(text string) []uint16 { value, _ := windows.UTF16FromString(text); return value }
func (u *desktopWindow) trayUpdate(status string) {
	if u.destroyed || (u.tray && u.trayStatus == status) {
		return
	}
	u.trayStatus = status
	data := u.trayData()
	operation := uintptr(1)
	if !u.tray {
		operation = 0
	}
	ok, _, _ := notifyIcon.Call(operation, uintptr(unsafe.Pointer(&data)))
	if ok != 0 {
		u.tray = true
		if operation == 0 {
			data.Version = 4
			notifyIcon.Call(4, uintptr(unsafe.Pointer(&data)))
		}
	}
}
func (u *desktopWindow) removeTray() {
	if u.tray {
		data := u.trayData()
		notifyIcon.Call(2, uintptr(unsafe.Pointer(&data)))
		u.tray = false
	}
}
func (u *desktopWindow) notify(notice Notice) {
	if !u.tray || u.destroyed {
		return
	}
	data := u.trayData()
	data.Flags = 0x10
	data.InfoFlags = 1 | 0x80
	if notice.Warning {
		data.InfoFlags = 2 | 0x80
	}
	copy(data.Title[:len(data.Title)-1], utf16Text(notice.Title))
	copy(data.Info[:len(data.Info)-1], utf16Text(notice.Message))
	notifyIcon.Call(1, uintptr(unsafe.Pointer(&data)))
}
func (u *desktopWindow) trayMenu() {
	if u.closing || u.destroyed || u.modal {
		return
	}
	menu, _, _ := createMenu.Call()
	if menu == 0 {
		return
	}
	defer destroyMenu.Call(menu)
	appendMenu.Call(menu, 0, wmShow, uintptr(unsafe.Pointer(wide("Open MicDrop"))))
	action := idStart
	label := "Start host"
	if u.controller.Snapshot().Phase != "stopped" {
		action = idStop
		label = "Stop host"
	}
	appendMenu.Call(menu, 0, uintptr(action), uintptr(unsafe.Pointer(wide(label))))
	appendMenu.Call(menu, 0, uintptr(idExit), uintptr(unsafe.Pointer(wide("Exit"))))
	var cursor point
	getCursorPos.Call(uintptr(unsafe.Pointer(&cursor)))
	setForeground.Call(u.hwnd)
	u.modal = true
	command, _, _ := trackMenu.Call(menu, 0x100|2, uintptr(cursor.X), uintptr(cursor.Y), 0, u.hwnd, 0)
	u.modal = false
	if command == wmShow {
		u.show()
	} else if command != 0 {
		u.action(int(command))
	}
	postMessage.Call(u.hwnd, 0, 0, 0)
}
func (u *desktopWindow) drawQR(item *drawItem) {
	if u.qr == nil {
		fillRect.Call(item.DC, uintptr(unsafe.Pointer(&item.Rect)), u.panelBrush)
		setTextColor.Call(item.DC, uintptr(u.foreground))
		setBackgroundColor.Call(item.DC, uintptr(u.panel))
		user32.NewProc("DrawTextW").Call(item.DC, uintptr(unsafe.Pointer(wide("Pair a phone to show\r\nits private QR code."))), ^uintptr(0), uintptr(unsafe.Pointer(&item.Rect)), 1|4|0x10)
		return
	}
	white, _, _ := gdi32.NewProc("GetStockObject").Call(0)
	black, _, _ := gdi32.NewProc("GetStockObject").Call(4)
	fillRect.Call(item.DC, uintptr(unsafe.Pointer(&item.Rect)), white)
	size := len(u.qr)
	scale := min(int(item.Rect.Right-item.Rect.Left), int(item.Rect.Bottom-item.Rect.Top)) / size
	if scale < 1 {
		return
	}
	x := int(item.Rect.Left) + (int(item.Rect.Right-item.Rect.Left)-size*scale)/2
	y := int(item.Rect.Top) + (int(item.Rect.Bottom-item.Rect.Top)-size*scale)/2
	for row, values := range u.qr {
		for col, dark := range values {
			if dark {
				r := rect{int32(x + col*scale), int32(y + row*scale), int32(x + (col+1)*scale), int32(y + (row+1)*scale)}
				fillRect.Call(item.DC, uintptr(unsafe.Pointer(&r)), black)
			}
		}
	}
}
func desktopProcedure(hwnd uintptr, message uint32, wparam, lparam uintptr) uintptr {
	u := activeWindow
	if u == nil {
		r, _, _ := defWindowProc.Call(hwnd, uintptr(message), wparam, lparam)
		return r
	}
	if message == u.taskbarMessage && u.taskbarMessage != 0 {
		u.tray = false
		u.trayUpdate(u.controller.Snapshot().Status)
		return 0
	}
	switch message {
	case wmShow:
		u.show()
		return 0
	case wmTray:
		switch uint32(lparam) & 0xffff {
		case 0x400, 0x401, 0x203, 0x405:
			if u.controller.Snapshot().Pending.ID != "" {
				u.selectPage(2)
			}
			u.show()
		case 0x7B, 0x205:
			u.trayMenu()
		}
		return 0
	case 0x111:
		id := int(wparam & 0xffff)
		notification := uint32(wparam >> 16)
		if notification == 1 && id == idDeviceList {
			u.renderConnections(u.controller.Snapshot())
			if u.page == 4 {
				u.openPhoneSettings()
			}
		} else if notification == 2 && id == idDeviceList {
			u.openPhoneSettings()
		} else if notification == 1 && id == idPhoneSettingsGroup {
			u.phoneSettingsGroupChanged()
		} else if notification == 1 && id == idPhoneSettingsList {
			u.phoneSettingSelected()
		} else if notification == 0 {
			u.action(id)
		}
		return 0
	case 0x113:
		u.tick()
		return 0
	case 0x5:
		if wparam != 1 {
			u.layout()
		}
		return 0
	case 0x24:
		var info minMaxInfo
		moveMemory.Call(uintptr(unsafe.Pointer(&info)), lparam, unsafe.Sizeof(info))
		info.MinTrackSize = point{int32(u.scale(720)), int32(u.scale(700))}
		moveMemory.Call(lparam, uintptr(unsafe.Pointer(&info)), unsafe.Sizeof(info))
		return 0
	case 0x2E0:
		u.dpi = int(wparam & 0xffff)
		u.fonts()
		var r rect
		moveMemory.Call(uintptr(unsafe.Pointer(&r)), lparam, unsafe.Sizeof(r))
		setWindowPos.Call(hwnd, 0, uintptr(r.Left), uintptr(r.Top), uintptr(r.Right-r.Left), uintptr(r.Bottom-r.Top), 0x14)
		u.layout()
		return 0
	case 0x1A:
		u.colors()
		invalidateRect.Call(hwnd, 0, 1)
		return 0
	case 0x14:
		var r rect
		getClientRect.Call(hwnd, uintptr(unsafe.Pointer(&r)))
		fillRect.Call(wparam, uintptr(unsafe.Pointer(&r)), u.backgroundBrush)
		line := rect{int32(u.scale(24)), int32(u.scale(136)), r.Right - int32(u.scale(24)), int32(u.scale(138))}
		fillRect.Call(wparam, uintptr(unsafe.Pointer(&line)), u.goldBrush)
		return 1
	case 0x138, 0x133, 0x134, 0x135:
		foreground, background, brush := u.foreground, u.background, u.backgroundBrush
		if lparam == u.controls[idTitle].handle || lparam == u.controls[idStatus].handle {
			foreground = u.gold
		}
		if message == 0x133 || message == 0x134 || lparam == u.controls[idPending].handle || lparam == u.controls[idPhoneFieldInt].handle || (lparam == u.controls[idPort].handle || lparam == u.controls[idLogRetention].handle) {
			foreground, background = u.palette.Text, u.palette.Surface
			available, _, _ := user32.NewProc("IsWindowEnabled").Call(lparam)
			if available == 0 || ((lparam == u.controls[idPort].handle || lparam == u.controls[idLogRetention].handle) && u.controller.Snapshot().Phase != "stopped") {
				foreground, background = u.palette.DisabledText, u.palette.Disabled
			}
			brush, _, _ = gdi32.NewProc("GetStockObject").Call(18) // DC_BRUSH
			gdi32.NewProc("SetDCBrushColor").Call(wparam, uintptr(background))
		}
		setTextColor.Call(wparam, uintptr(foreground))
		setBackgroundColor.Call(wparam, uintptr(background))
		return brush
	case 0x2C: // WM_MEASUREITEM arrives while owner-drawn controls are created.
		if u.measureControl(lparam) {
			return 1
		}
	case 0x2B:
		var item drawItem
		moveMemory.Call(uintptr(unsafe.Pointer(&item)), lparam, unsafe.Sizeof(item))
		if u.drawControl(&item) {
			return 1
		}
		if item.ID == idQR {
			saved, _, _ := gdi32.NewProc("SaveDC").Call(item.DC)
			u.drawQR(&item)
			gdi32.NewProc("RestoreDC").Call(item.DC, saved)
			return 1
		}
	case 0x10:
		if u.tray {
			showWindow.Call(hwnd, 0)
		} else {
			u.closing = true
			u.controller.Stop()
			u.tick()
		}
		return 0
	case 0x11:
		// A normal Exit remains asynchronous. Windows logoff gets a bounded cleanup
		// opportunity; process termination will release any remaining OS resources.
		select {
		case <-u.controller.Stop():
		case <-time.After(5 * time.Second):
		}
		return 1
	case 0x16:
		if wparam != 0 {
			u.removeTray()
			destroyWindow.Call(hwnd)
		}
		return 0
	case 0x2:
		u.removeTray()
		u.destroyed = true
		postQuitMessage.Call(0)
		return 0
	}
	r, _, _ := defWindowProc.Call(hwnd, uintptr(message), wparam, lparam)
	return r
}
