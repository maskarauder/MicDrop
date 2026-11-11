// SPDX-License-Identifier: MPL-2.0
//go:build darwin && arm64

package desktop

/*
#cgo darwin CFLAGS: -fobjc-arc -mmacosx-version-min=14.2
#cgo darwin LDFLAGS: -mmacosx-version-min=14.2 -framework Cocoa -framework UserNotifications -framework UniformTypeIdentifiers

#include <stdlib.h>
#include "appkit_darwin.h"
*/
import "C"

import (
	"errors"
	"fmt"
	"os"
	"os/signal"
	"path/filepath"
	"runtime"
	"strconv"
	"strings"
	"sync/atomic"
	"syscall"
	"time"
	"unsafe"

	"github.com/maskarauder/MicDrop/internal/version"
	qrcode "github.com/skip2/go-qrcode"
)

const (
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

type uiResult struct {
	devices  []AudioDevice
	networks []Network
	remote   string
	err      error
	refresh  bool
	message  string
}

type desktopWindow struct {
	backend                    Backend
	controller                 *Controller
	settings                   Settings
	directory                  string
	page                       int
	headlessTest               bool
	trayRunning, trayConnected bool
	trayStatus                 string
	busy, closing, destroyed   bool
	modal                      bool
	requestShow                atomic.Bool
	jobs                       chan uiResult
	closed                     chan struct{}
	devices                    []AudioDevice
	networks                   []Network
	captureIDs, microphoneIDs  []string
	phoneKeys                  []string
	phoneDisplay               string
	deviceKeys                 []string
	deviceDisplay              string
	phoneEditor                *phoneSettingsEditor
	currentLink                string
	qr                         [][]bool
	lastRevision               uint64
	labelID                    int
}

var activeWindow *desktopWindow
var uiTestQueue = make(chan func(), 32)

//export goMicDropTick
func goMicDropTick() {
	if activeWindow != nil {
		activeWindow.tick()
	}
}

//export goMicDropShow
func goMicDropShow() {
	if activeWindow != nil {
		if activeWindow.controller.Snapshot().Pending.ID != "" {
			activeWindow.selectPage(2)
		}
		activeWindow.show()
	}
}

//export goMicDropEvent
func goMicDropEvent(id C.int, kind C.int) {
	u := activeWindow
	if u == nil {
		return
	}
	ctrlID := int(id)
	evKind := int(kind)
	if evKind == C.MD_EVENT_CHANGE && ctrlID == idDeviceList {
		u.renderConnections(u.controller.Snapshot())
		if u.page == 4 {
			u.openPhoneSettings()
		}
		return
	}
	if evKind == C.MD_EVENT_DBLCLK && ctrlID == idDeviceList {
		u.openPhoneSettings()
		return
	}
	if evKind == C.MD_EVENT_CHANGE && ctrlID == idPhoneSettingsGroup {
		u.phoneSettingsGroupChanged()
		return
	}
	if evKind == C.MD_EVENT_CHANGE && ctrlID == idPhoneSettingsList {
		u.phoneSettingSelected()
		return
	}
	if evKind == C.MD_EVENT_CLICK {
		u.action(ctrlID)
	}
}

//export goMicDropDrainTestQueue
func goMicDropDrainTestQueue() {
	for {
		select {
		case fn := <-uiTestQueue:
			fn()
		default:
			return
		}
	}
}

func ShowError(err error) {
	if err == nil {
		return
	}
	if C.md_app_is_main_thread() == 0 {
		return
	}
	cs := C.CString(err.Error())
	defer C.free(unsafe.Pointer(cs))
	C.md_ui_show_error(cs)
}

func Run(backend Backend, directory string, background bool) error {
	if runtime.GOARCH != "arm64" {
		return errors.New("MicDrop desktop on macOS requires Apple Silicon (arm64)")
	}
	return runWindow(backend, directory, background, false)
}

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

func runWindow(backend Backend, directory string, background bool, headlessTest bool) error {
	runtime.LockOSThread()
	defer runtime.UnlockOSThread()

	if C.md_app_is_main_thread() == 0 {
		return errors.New("macOS desktop UI must start on the main OS thread")
	}

	var reopenCh chan os.Signal
	if !headlessTest {
		reopenCh = make(chan os.Signal, 1)
		signal.Notify(reopenCh, syscall.SIGUSR1)
		defer signal.Stop(reopenCh)
	}

	lockFile, alreadyRunning, err := acquireInstanceLock(directory)
	if err != nil {
		return err
	}
	if alreadyRunning {
		return nil
	}
	defer func() {
		_ = syscall.Flock(int(lockFile.Fd()), syscall.LOCK_UN)
		_ = lockFile.Close()
	}()

	settings, err := LoadSettings(directory)
	if err != nil {
		return err // Never overwrite corrupt/newer settings.
	}

	u := &desktopWindow{
		backend:      backend,
		controller:   NewController(backend),
		settings:     settings,
		directory:    directory,
		headlessTest: headlessTest,
		jobs:         make(chan uiResult, 1),
		closed:       make(chan struct{}),
		labelID:      1000,
	}
	activeWindow = u
	defer func() {
		activeWindow = nil
		close(u.closed)
	}()

	cTitle := C.CString("MicDrop " + version.Current().Version)
	var errBuf [256]C.char
	headlessFlag := C.int(0)
	if headlessTest {
		headlessFlag = 1
	}
	ok := C.md_app_init(cTitle, headlessFlag, C.int(idStart), C.int(idStop), C.int(idExit), &errBuf[0], C.size_t(len(errBuf)))
	C.free(unsafe.Pointer(cTitle))
	if ok == 0 {
		return errors.New(C.GoString(&errBuf[0]))
	}
	defer C.md_app_cleanup()

	if reopenCh != nil {
		go func() {
			for {
				select {
				case <-reopenCh:
					u.requestShow.Store(true)
					C.md_app_dispatch_wake()
				case <-u.closed:
					return
				}
			}
		}()
	}

	if err := u.build(); err != nil {
		return err
	}
	C.md_ui_layout()
	u.selectPage(0)
	u.trayUpdate("Stopped", false, false)
	u.refresh()

	if background {
		C.md_app_hide_window()
		// Startup is explicitly opted in. Existing approved phones still authorize
		// each session; neither startup nor pairing opens capture by itself.
		if err := u.controller.Start(settings); err != nil {
			u.show()
			u.showErr(err)
		}
	} else {
		u.show()
	}

	C.md_app_run()
	<-u.controller.Stop()
	return nil
}

func uiSetText(id int, text string) {
	cs := C.CString(text)
	C.md_ui_set_text(C.int(id), cs)
	C.free(unsafe.Pointer(cs))
}

func uiTextAt(id int) string {
	ptr := C.md_ui_copy_text(C.int(id))
	if ptr == nil {
		return ""
	}
	defer C.free(unsafe.Pointer(ptr))
	return C.GoString(ptr)
}

func uiEnabled(id int, yes bool) {
	v := C.int(0)
	if yes {
		v = 1
	}
	C.md_ui_set_enabled(C.int(id), v)
}

func uiIsEnabled(id int) bool {
	return C.md_ui_is_enabled(C.int(id)) != 0
}

func uiReadOnly(id int, yes bool) {
	v := C.int(0)
	if yes {
		v = 1
	}
	C.md_ui_set_readonly(C.int(id), v)
}

func uiIsReadOnly(id int) bool {
	return C.md_ui_is_readonly(C.int(id)) != 0
}

func uiCheck(id int, yes bool) {
	v := C.int(0)
	if yes {
		v = 1
	}
	C.md_ui_set_checked(C.int(id), v)
}

func uiChecked(id int) bool {
	return C.md_ui_is_checked(C.int(id)) != 0
}

func withCStringArray(labels []string, fn func(**C.char, C.int)) {
	if len(labels) == 0 {
		fn(nil, 0)
		return
	}
	ptrSize := unsafe.Sizeof((*C.char)(nil))
	raw := C.malloc(C.size_t(len(labels)) * C.size_t(ptrSize))
	if raw == nil {
		fn(nil, 0)
		return
	}
	defer C.free(raw)
	slice := unsafe.Slice((**C.char)(raw), len(labels))
	for i, s := range labels {
		slice[i] = C.CString(s)
	}
	defer func() {
		for _, p := range slice {
			C.free(unsafe.Pointer(p))
		}
	}()
	fn((**C.char)(raw), C.int(len(labels)))
}

func uiComboItems(id int, labels []string, selected int) {
	withCStringArray(labels, func(arr **C.char, count C.int) {
		C.md_ui_set_popup_items(C.int(id), arr, count, C.int(selected))
	})
}

func uiComboSelected(id int) int {
	return int(C.md_ui_popup_selected(C.int(id)))
}

func uiListItems(id int, labels []string, selected int) {
	withCStringArray(labels, func(arr **C.char, count C.int) {
		C.md_ui_set_list_items(C.int(id), arr, count, C.int(selected))
	})
}

func uiListSelected(id int) int {
	return int(C.md_ui_list_selected(C.int(id)))
}

func (u *desktopWindow) add(id, kind int, title string, page, x, y, w, h int) error {
	cs := C.CString(title)
	ok := C.md_ui_add_control(C.int(id), C.int(kind), cs, C.int(page), C.int(x), C.int(y), C.int(w), C.int(h))
	C.free(unsafe.Pointer(cs))
	if ok == 0 {
		return fmt.Errorf("create macOS control %d failed", id)
	}
	return nil
}

func (u *desktopWindow) build() error {
	var first error
	add := func(id, kind int, title string, page, x, y, w, h int) {
		if first == nil {
			first = u.add(id, kind, title, page, x, y, w, h)
		}
	}
	label := func(text string, page, x, y, w, h int) {
		u.labelID++
		add(u.labelID, C.MD_KIND_LABEL, text, page, x, y, w, h)
	}
	button := func(id int, text string, page, x, y, w int) {
		add(id, C.MD_KIND_BUTTON, text, page, x, y, w, 32)
	}
	combo := func(id, page, x, y, w int) {
		add(id, C.MD_KIND_POPUP, "", page, x, y, w, 28)
	}

	// Persistent header & navigation bar.
	add(idTitle, C.MD_KIND_TITLE, "MicDrop", -1, 24, 18, 148, 32)
	add(idStatus, C.MD_KIND_LABEL, "Stopped", -1, 24, 54, 148, 64)
	add(idDeviceCount, C.MD_KIND_LABEL, "0 devices connected", -1, 184, 16, -268, 22)
	add(idDeviceList, C.MD_KIND_LIST, "", -1, 184, 40, -268, 54)
	add(idDeviceMetrics, C.MD_KIND_LABEL, "Select a phone to view its connection.", -1, 184, 98, -24, 38)
	button(idStart, "Start host", -1, -252, 24, 108)
	button(idStop, "Stop host", -1, -132, 24, 108)
	button(idDeviceSettings, "Device settings…", -1, -252, 62, 228)

	button(idAudio, "Audio", -1, 24, 150, 116)
	button(idConnection, "Connection", -1, 148, 150, 136)
	button(idPhones, "Phones", -1, 292, 150, 116)
	button(idOptions, "Options", -1, 416, 150, 116)

	// Persistent footer.
	add(idMessage, C.MD_KIND_LABEL, "Choose your audio devices and LAN adapter, then save and start.", -1, 24, -86, -24, 38)
	button(idSave, "Save settings", -1, 24, -42, 140)
	button(idLogs, "Open logs", -1, 176, -42, 124)
	button(idExit, "Quit", -1, -124, -42, 100)

	// Page 0: Audio.
	label("Audio routing", 0, 24, 206, -24, 22)
	label("Desktop audio source", 0, 24, 240, -24, 20)
	combo(idCapture, 0, 24, 264, -24)
	label("macOS 14.2+ System Audio Recording permission is requested when a phone session starts.", 0, 24, 298, -24, 22)
	label("Phone microphone destination", 0, 24, 336, -24, 20)
	combo(idMicrophone, 0, 24, 360, -24)
	label("Choose a virtual audio cable's output device (for example BlackHole 2ch).\nIn Discord, Zoom, or another receiving app, choose that same virtual cable as the microphone input.", 0, 24, 394, -24, 44)
	button(idRefreshAudio, "Refresh devices", 0, 24, 452, 156)
	button(idCableHelp, "Audio setup…", 0, 192, 452, 148)

	// Page 1: Connection.
	label("LAN adapter", 1, 24, 206, -24, 20)
	combo(idNetwork, 1, 24, 230, -200)
	button(idRefreshNetwork, "Refresh network", 1, -184, 228, 160)
	label("Control port", 1, 24, 276, 120, 20)
	add(idPort, C.MD_KIND_EDIT, strconv.Itoa(u.settings.Port), 1, 24, 300, 112, 26)
	add(idRemote, C.MD_KIND_CHECKBOX, "Enable remote connections", 1, 164, 300, -24, 26)
	add(idRemoteStatus, C.MD_KIND_LABEL, "Reading remote configuration…", 1, 24, 342, -24, 38)
	button(idImport, "Import remote config…", 1, 24, 390, 204)
	button(idForget, "Forget remote config", 1, 240, 390, 196)
	button(idFirewall, "macOS Firewall…", 1, 24, 446, 196)

	// Page 2: Phones.
	label("Approved phones", 2, 24, 206, -324, 22)
	add(idPhoneList, C.MD_KIND_LIST, "", 2, 24, 232, -324, 128)
	button(idRemove, "Remove selected phone", 2, 24, 370, 224)
	button(idPair, "Pair a phone", 2, 24, 410, 164)
	add(idPending, C.MD_KIND_MULTILINE, "No pending approval.", 2, 24, 450, -324, 68)
	button(idApprove, "Approve", 2, 24, 528, 112)
	button(idReject, "Reject", 2, 148, 528, 112)
	label("Private pairing invitation", 2, -284, 206, 260, 22)
	add(idQR, C.MD_KIND_QR, "", 2, -284, 232, 260, 260)
	button(idCopy, "Copy pairing link", 2, -284, 502, 260)
	add(idExpiry, C.MD_KIND_LABEL, "Pairing is closed.", 2, -284, 540, 260, 24)

	// Page 3: Options.
	add(idStartup, C.MD_KIND_CHECKBOX, "Start host when I sign in to macOS", 3, 24, 214, -24, 26)
	add(idNotifications, C.MD_KIND_CHECKBOX, "Show connection and pairing notifications", 3, 24, 252, -24, 26)
	add(idSaveLogs, C.MD_KIND_CHECKBOX, "Save connection logs", 3, 24, 300, -24, 26)
	label("Keep newest connection logs (0 keeps all)", 3, 24, 340, -24, 22)
	add(idLogRetention, C.MD_KIND_EDIT, strconv.Itoa(u.settings.LogRetention), 3, 24, 366, 112, 26)
	label("A positive limit keeps the newest logs and deletes the oldest. Active logs are kept.\nTurning logging off keeps existing files. Save while the host is stopped.", 3, 24, 404, -24, 56)

	// Page 4: Phone settings editor.
	add(idPhoneSettingsTitle, C.MD_KIND_LABEL, "Phone settings", 4, 24, 206, -24, 24)
	combo(idPhoneSettingsGroup, 4, 24, 240, 348)
	button(idPhoneSettingsBack, "Back", 4, -144, 238, 120)
	add(idPhoneSettingsList, C.MD_KIND_LIST, "", 4, 24, 280, 348, 260)
	add(idPhoneFieldLabel, C.MD_KIND_LABEL, "Select a setting.", 4, 396, 280, -24, 54)
	add(idPhoneFieldBool, C.MD_KIND_CHECKBOX, "Enabled", 4, 396, 342, -24, 28)
	add(idPhoneFieldInt, C.MD_KIND_EDIT, "", 4, 396, 342, 140, 26)
	combo(idPhoneFieldChoice, 4, 396, 342, -24)
	add(idPhoneFieldEffect, C.MD_KIND_LABEL, "", 4, 396, 380, -24, 48)
	button(idPhoneSettingsApply, "Apply setting", 4, 396, 438, 158)
	button(idPhoneSettingsReload, "Reload", 4, 566, 438, 118)
	add(idPhoneSettingsStatus, C.MD_KIND_LABEL, "", 4, 396, 482, -24, 76)

	if first != nil {
		return first
	}

	uiCheck(idRemote, u.settings.Remote)
	uiCheck(idNotifications, u.settings.Notifications)
	uiCheck(idSaveLogs, u.settings.SaveLogs)
	startup, err := startupEnabled()
	if err != nil {
		uiSetText(idMessage, "macOS login startup preference could not be read.")
	}
	uiCheck(idStartup, startup)
	u.tick()
	return nil
}

func (u *desktopWindow) selectPage(page int) {
	u.page = page
	C.md_ui_select_page(C.int(page))
	for i, id := range []int{idAudio, idConnection, idPhones, idOptions} {
		text := []string{"Audio", "Connection", "Phones", "Options"}[i]
		if i == page {
			text = "• " + text
		}
		uiSetText(id, text)
	}
	u.phoneEditorVisibility()
}

func (u *desktopWindow) show() {
	C.md_app_show_window(1)
}

func (u *desktopWindow) preferences() (Settings, error) {
	s := u.settings
	selection := uiComboSelected(idNetwork)
	if selection >= 0 && selection < len(u.networks) {
		s.Interface = u.networks[selection].Interface
		s.AddressHint = u.networks[selection].Address
	}
	selection = uiComboSelected(idCapture)
	if selection >= 0 && selection < len(u.captureIDs) {
		s.CaptureDevice = u.captureIDs[selection]
	}
	selection = uiComboSelected(idMicrophone)
	if selection >= 0 && selection < len(u.microphoneIDs) {
		s.MicrophoneDevice = u.microphoneIDs[selection]
	}
	port, err := strconv.Atoi(strings.TrimSpace(uiTextAt(idPort)))
	if err != nil {
		return s, errors.New("enter a LAN port between 1 and 65535")
	}
	s.Port = port
	s.Remote = uiChecked(idRemote)
	s.Notifications = uiChecked(idNotifications)
	s.SaveLogs = uiChecked(idSaveLogs)
	retention, err := strconv.Atoi(strings.TrimSpace(uiTextAt(idLogRetention)))
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
	uiSetText(idMessage, "Settings saved. Existing paired phones are unchanged.")
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
			C.md_app_dispatch_wake()
		case <-u.closed:
		}
	}()
}

func (u *desktopWindow) refresh() {
	if u.busy {
		return
	}
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

func (u *desktopWindow) inventory(r uiResult) {
	u.devices = r.devices
	for _, input := range []struct {
		id           int
		saved, first string
	}{
		{idCapture, u.settings.CaptureDevice, "Default macOS output"},
		{idMicrophone, u.settings.MicrophoneDevice, "Disabled — desktop playback only"},
	} {
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
		uiComboItems(input.id, labels, selection)
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
	uiComboItems(idNetwork, labels, selection)
	uiSetText(idRemoteStatus, r.remote)
}

func (u *desktopWindow) showErr(err error) {
	if err == nil || u.closing || u.destroyed || u.modal {
		return
	}
	if u.headlessTest {
		uiSetText(idMessage, err.Error())
		return
	}
	u.modal = true
	defer func() { u.modal = false }()
	ShowError(err)
}

func (u *desktopWindow) askConfirm(text string) bool {
	if u.closing || u.destroyed || u.modal || u.headlessTest {
		return false
	}
	u.modal = true
	defer func() { u.modal = false }()
	cs := C.CString(text)
	defer C.free(unsafe.Pointer(cs))
	return C.md_ui_confirm(cs) != 0
}

func (u *desktopWindow) pickConfig() (string, error) {
	if u.closing || u.destroyed || u.modal || u.headlessTest {
		return "", nil
	}
	u.modal = true
	defer func() { u.modal = false }()
	ptr := C.md_ui_choose_json_file()
	if ptr == nil {
		return "", nil
	}
	defer C.free(unsafe.Pointer(ptr))
	return C.GoString(ptr), nil
}

func (u *desktopWindow) trayUpdate(status string, running, connected bool) {
	if u.destroyed {
		return
	}
	if u.trayStatus == status && u.trayRunning == running && u.trayConnected == connected {
		return
	}
	u.trayStatus = status
	u.trayRunning = running
	u.trayConnected = connected
	cs := C.CString(status)
	runFlag := C.int(0)
	if running {
		runFlag = 1
	}
	connFlag := C.int(0)
	if connected {
		connFlag = 1
	}
	C.md_ui_update_tray(cs, runFlag, connFlag)
	C.free(unsafe.Pointer(cs))
}

func (u *desktopWindow) notify(notice Notice) {
	if u.destroyed || u.headlessTest {
		return
	}
	cTitle := C.CString(notice.Title)
	cBody := C.CString(notice.Message)
	warnFlag := C.int(0)
	if notice.Warning {
		warnFlag = 1
	}
	C.md_ui_notify(cTitle, cBody, warnFlag)
	C.free(unsafe.Pointer(cTitle))
	C.free(unsafe.Pointer(cBody))
}

func (u *desktopWindow) tick() {
	if u.destroyed {
		return
	}
	if u.requestShow.Swap(false) {
		u.show()
	}
	select {
	case r := <-u.jobs:
		u.busy = false
		if r.refresh {
			u.inventory(r)
		} else {
			remote, _ := u.backend.RemoteStatus()
			uiSetText(idRemoteStatus, remote)
		}
		if r.err != nil {
			if u.modal && !u.closing {
				uiSetText(idMessage, r.err.Error())
			} else {
				u.showErr(r.err)
			}
		} else if r.message != "" {
			uiSetText(idMessage, r.message)
		}
	default:
	}

	state := u.controller.Snapshot()
	u.renderConnections(state)
	stopped, ready := state.Phase == "stopped", state.Phase == "ready"
	if u.closing && stopped && !u.busy && !u.modal {
		u.destroyed = true
		C.md_app_stop_loop()
		return
	}

	editable := stopped && !u.busy && !u.closing
	for _, id := range []int{
		idStart, idSave, idCapture, idMicrophone, idRefreshAudio,
		idNetwork, idRefreshNetwork, idRemote, idImport, idForget,
		idNotifications, idSaveLogs,
	} {
		uiEnabled(id, editable)
	}
	uiReadOnly(idPort, !editable)
	uiReadOnly(idLogRetention, !editable || !uiChecked(idSaveLogs))
	uiEnabled(idStop, !stopped && state.Phase != "stopping" && !u.closing)
	uiEnabled(idStartup, !u.closing)
	for _, id := range []int{idPair, idRemove, idPhoneList} {
		uiEnabled(id, ready && !u.closing)
	}
	for _, id := range []int{idApprove, idReject} {
		uiEnabled(id, ready && state.Pending.ID != "" && !u.closing)
	}
	uiEnabled(idCopy, state.Link != "" && !u.closing)

	if uiTextAt(idStatus) != state.Status {
		uiSetText(idStatus, state.Status)
	}
	if state.Revision != u.lastRevision {
		u.lastRevision = state.Revision
		if state.Message != "" {
			uiSetText(idMessage, state.Message)
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
			idx := uiListSelected(idPhoneList)
			if idx >= 0 && idx < len(u.phoneKeys) {
				selected = u.phoneKeys[idx]
			}
			u.phoneDisplay = phoneDisplay.String()
			u.phoneKeys = nil
			var labels []string
			selIndex := -1
			for i, phone := range state.Phones {
				u.phoneKeys = append(u.phoneKeys, phone.Key)
				labels = append(labels, phone.Name+"  ·  "+phone.Key[:min(12, len(phone.Key))])
				if phone.Key == selected {
					selIndex = i
				}
			}
			uiListItems(idPhoneList, labels, selIndex)
		}
	}

	pending := "No pending approval."
	if state.Pending.ID != "" {
		pending = "Unverified name: " + state.Pending.Name + "\nRequest ID: " + state.Pending.ID + "\nPhone key: " + state.Pending.Key
	}
	if uiTextAt(idPending) != pending {
		uiSetText(idPending, pending)
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
		if pixels, size := renderQRBitmapRGBA(u.qr, 520); len(pixels) > 0 && size > 0 {
			C.md_ui_set_qr_rgba((*C.uint8_t)(unsafe.Pointer(&pixels[0])), C.int(size))
		} else {
			C.md_ui_set_qr_rgba(nil, 0)
		}
	}

	expiry := "Pairing is closed."
	if state.Link != "" {
		expiry = "Private · expires in " + strconv.Itoa(max(0, int(time.Until(state.Expires).Seconds()))) + " seconds"
	}
	if uiTextAt(idExpiry) != expiry {
		uiSetText(idExpiry, expiry)
	}

	u.trayUpdate(state.Status, !stopped, state.SessionState == "connected")
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
		if u.askConfirm("Remove this Mac's remote configuration? LAN pairing is kept. Remote access will need another configuration import.") {
			if u.closing || u.destroyed || u.busy || u.controller.Snapshot().Phase != "stopped" {
				return
			}
			u.work(func() uiResult {
				return uiResult{err: u.backend.ForgetRemote(), message: "Remote configuration removed. Disable remote connections to use LAN only."}
			})
		}
	case idStartup:
		yes := uiChecked(idStartup)
		if yes {
			if state.Phase != "stopped" || u.busy {
				u.showErr(errors.New("stop the host and save its settings before enabling startup"))
				uiCheck(idStartup, false)
				return
			}
			if err := u.save(); err != nil {
				u.showErr(err)
				uiCheck(idStartup, false)
				return
			}
			networks, err := Networks()
			if err == nil {
				_, err = ResolveNetwork(u.settings, networks)
			}
			if err != nil {
				u.showErr(err)
				uiCheck(idStartup, false)
				return
			}
		}
		if err := setStartup(yes); err != nil {
			u.showErr(err)
			actual, _ := startupEnabled()
			uiCheck(idStartup, actual)
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
			if !u.askConfirm("Approve this phone only if its request ID matches:\n\n" + pending.ID + "\n\nUnverified name: " + pending.Name + "\nPhone key: " + pending.Key) {
				return
			}
			action = "approve"
		}
		u.showErr(u.controller.Command(Command{Action: action, Value: pending.ID}))
	case idRemove:
		idx := uiListSelected(idPhoneList)
		if idx < 0 || idx >= len(u.phoneKeys) {
			u.showErr(errors.New("select a paired phone first"))
			return
		}
		key := u.phoneKeys[idx]
		if u.askConfirm("Remove this phone and stop its active stream?\n\nPhone key: " + key) {
			u.showErr(u.controller.Command(Command{Action: "revoke", Value: key}))
		}
	case idCopy:
		if state.Link != "" {
			cs := C.CString(state.Link)
			ok := C.md_ui_copy_clipboard(cs)
			C.free(unsafe.Pointer(cs))
			if ok == 0 {
				u.showErr(errors.New("cannot copy pairing link"))
			}
		}
	case idLogs:
		directory := filepath.Join(u.directory, "logs")
		if err := os.MkdirAll(directory, 0700); err != nil {
			u.showErr(err)
		} else {
			cs := C.CString(directory)
			ok := C.md_ui_open_path(cs)
			C.free(unsafe.Pointer(cs))
			if ok == 0 {
				u.showErr(errors.New("macOS could not open the logs folder"))
			}
		}
	case idFirewall:
		if C.md_ui_open_firewall_settings() == 0 {
			u.showErr(errors.New("macOS Firewall settings could not be opened"))
		}
	case idCableHelp:
		if !u.modal && !u.headlessTest {
			u.modal = true
			cTitle := C.CString("macOS audio and virtual microphone setup")
			cMsg := C.CString(
				"Desktop audio capture uses macOS 14.2+ CoreAudio Process Taps. When a phone connects for the first time, allow MicDrop under System Settings > Privacy & Security > Screen & System Audio Recording.\n\n" +
					"For phone microphone return, install a user-space virtual audio cable separately (for example BlackHole 2ch). Choose that virtual cable here as the Phone microphone destination, and select the same virtual cable as the microphone input in Discord, Zoom, or your voice app.\n\n" +
					"Desktop playback works with microphone return disabled. MicDrop does not install or bundle an audio driver.")
			C.md_ui_show_info(cTitle, cMsg)
			C.free(unsafe.Pointer(cTitle))
			C.free(unsafe.Pointer(cMsg))
			u.modal = false
		}
	case idExit:
		u.closing = true
		u.controller.Stop()
	}
	u.tick()
}

func wakeTestQueue() {
	C.md_app_wake_test()
}

func triggerControlForTest(id, kind int) {
	C.md_ui_trigger(C.int(id), C.int(kind))
}

func popupCountForTest(id int) int {
	return int(C.md_ui_popup_count(C.int(id)))
}

func popupFindExactForTest(id int, title string) int {
	cs := C.CString(title)
	defer C.free(unsafe.Pointer(cs))
	return int(C.md_ui_popup_find_exact(C.int(id), cs))
}

func controlBoundsForTest(id int) (bool, int, int, int, int, int, int) {
	var x, y, w, h, winW, winH C.int
	ok := C.md_ui_check_bounds(C.int(id), &x, &y, &w, &h, &winW, &winH)
	return ok != 0, int(x), int(y), int(w), int(h), int(winW), int(winH)
}

func capturePNGForTest(path string) bool {
	cs := C.CString(path)
	defer C.free(unsafe.Pointer(cs))
	return C.md_ui_capture_png(cs) != 0
}
