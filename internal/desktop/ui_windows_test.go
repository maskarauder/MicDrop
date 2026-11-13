//go:build windows

package desktop

import (
	"bytes"
	"context"
	"encoding/base64"
	"encoding/json"
	"fmt"
	"image"
	"image/png"
	"os"
	"path/filepath"
	"runtime"
	"runtime/debug"
	"strings"
	"testing"
	"time"
	"unicode/utf16"
	"unsafe"

	"github.com/maskarauder/MicDrop/internal/phonecontrol"
	"golang.org/x/sys/windows"
)

func TestWindowsStructureLayouts(t *testing.T) {
	if idExit != 109 {
		t.Fatal("installer compatibility requires stable desktop Exit command 109")
	}
	// These structures cross the Win32 ABI; a layout error can corrupt memory.
	if unsafe.Sizeof(windowClass{}) != 80 || unsafe.Sizeof(windowMessage{}) != 48 || unsafe.Sizeof(iconData{}) != 976 || unsafe.Sizeof(openFileName{}) != 152 || unsafe.Sizeof(drawItem{}) != 64 {
		t.Fatalf("unexpected Win64 layouts: class=%d message=%d icon=%d picker=%d draw=%d", unsafe.Sizeof(windowClass{}), unsafe.Sizeof(windowMessage{}), unsafe.Sizeof(iconData{}), unsafe.Sizeof(openFileName{}), unsafe.Sizeof(drawItem{}))
	}
	if unsafe.Sizeof(themeMeasureItem{}) != 32 || unsafe.Sizeof(themeComboBoxInfo{}) != 64 || unsafe.Sizeof(themePaintStruct{}) != 72 {
		t.Fatalf("unexpected theme layouts: measure=%d combo=%d paint=%d", unsafe.Sizeof(themeMeasureItem{}), unsafe.Sizeof(themeComboBoxInfo{}), unsafe.Sizeof(themePaintStruct{}))
	}
}
func TestWindowsDesktopControls(t *testing.T) {
	class := fmt.Sprintf("MicDrop.Desktop.Test.%d.%d", os.Getpid(), time.Now().UnixNano())
	started := make(chan func(Event), 1)
	phoneEdits := make(chan Command, 4)
	hostDone := make(chan struct{})
	finished := make(chan error, 1)
	backend := Backend{
		Run: func(ctx context.Context, _ Settings, commands <-chan Command, emit func(Event)) error {
			emit(Event{Kind: "ready", Message: "LAN control ready (test host)"})
			started <- emit
			defer close(hostDone)
			for {
				select {
				case <-ctx.Done():
					return nil
				case command := <-commands:
					if command.Action == "pair" {
						emit(Event{Kind: "invitation", Link: "micdrop://pair/v1/test-fixture-not-a-credential", Expires: time.Now().Add(time.Minute)})
					} else if command.Action == "phone_settings" {
						emit(Event{Kind: "phone_settings_queued", PhoneKey: command.Value, Session: command.Session})
						phoneEdits <- command
					}
				}
			}
		},
		Devices: func() ([]AudioDevice, error) {
			return []AudioDevice{{ID: "speaker", Name: "Speakers (test fixture)", Default: true}, {ID: "cable", Name: "CABLE Input (test fixture)"}}, nil
		},
		RemoteStatus: func() (string, error) { return "No remote configuration imported", nil },
	}
	directory := t.TempDir()
	settings := Defaults()
	settings.Notifications = false
	settings.Remote = true // Render a checked, locked option through the fake backend.
	if err := SaveSettings(directory, settings); err != nil {
		t.Fatal(err)
	}
	go func() { finished <- runWindow(backend, directory, true, class) }()
	var emit func(Event)
	select {
	case emit = <-started:
	case err := <-finished:
		t.Fatalf("window did not start: %v", err)
	case <-time.After(10 * time.Second):
		t.Fatal("window startup timed out")
	}
	classPtr := wide(class)
	hwnd, _, _ := findWindow.Call(uintptr(unsafe.Pointer(classPtr)), 0)
	runtime.KeepAlive(classPtr)
	if hwnd == 0 {
		t.Fatal("owned test window missing")
	}
	defer func() {
		postMessage.Call(hwnd, 0x111, uintptr(idExit), 0)
		select {
		case err := <-finished:
			if err != nil {
				t.Error(err)
			}
		case <-time.After(10 * time.Second):
			t.Error("desktop Exit did not finish cleanup")
		}
	}()
	child := func(id int) uintptr {
		h, _, _ := user32.NewProc("GetDlgItem").Call(hwnd, uintptr(id))
		if h == 0 {
			t.Fatalf("missing native control %d", id)
		}
		return h
	}
	wait := func(condition func() bool) {
		t.Helper()
		deadline := time.Now().Add(5 * time.Second)
		for !condition() {
			if time.Now().After(deadline) {
				t.Fatal("UI did not reach expected state")
			}
			time.Sleep(20 * time.Millisecond)
		}
	}
	wait(func() bool { return textAt(child(idStatus)) == "Ready for a paired phone" })
	wait(func() bool { return int32(send(child(idCapture), 0x146, 0, 0)) > 0 })
	if int32(send(child(idCapture), 0x147, 0, 0)) != 0 || int32(send(child(idMicrophone), 0x147, 0, 0)) != 0 {
		t.Fatal("initial audio selections are missing")
	}
	if enabled, _, _ := user32.NewProc("IsWindowEnabled").Call(child(idCapture)); enabled != 0 {
		t.Fatal("capture selection editable while running")
	}
	portStyle, _, _ := user32.NewProc("GetWindowLongPtrW").Call(child(idPort), ^uintptr(15))
	if portStyle&0x800 == 0 {
		t.Fatal("port must stay read-only while running")
	}
	if found := int32(sendText(child(idCapture), 0x158, ^uintptr(0), "CABLE Input (test fixture)")); found != 2 {
		t.Fatal("owner drawing lost native combo strings/type-ahead", found)
	}
	send(hwnd, 0x111, uintptr(idPhones), 0)
	send(hwnd, 0x111, uintptr(idPair), 0)
	wait(func() bool { return textAt(child(idExpiry)) != "Pairing is closed." })
	phoneKey := strings.Repeat("1", 64)
	otherKey := strings.Repeat("2", 64)
	emit(Event{Kind: "phones", Phones: []Phone{{Name: "Pixel 8 (test)", Key: phoneKey}, {Name: "Second phone (test)", Key: otherKey}}})
	emit(Event{Kind: "session_begin", Session: 1, PhoneKey: phoneKey})
	emit(Event{Kind: "session_status", Session: 1, State: "connected"})
	wait(func() bool { return textAt(child(idStatus)) == "Phone connected" })
	// A double-click opens the editor without a snapshot, so it must say why:
	// an older phone needs an update, not another reconnect.
	waiting := DeviceConnection{Key: phoneKey, UpdatedAt: time.Now(), SettingsSupported: true}
	emit(Event{Kind: "phone_state", Session: 1, Connection: &waiting})
	send(hwnd, 0x111, uintptr(idDeviceList)|2<<16, 0) // LBN_DBLCLK
	wait(func() bool {
		return strings.Contains(textAt(child(idPhoneSettingsStatus)), "Waiting for the phone to share")
	})
	older := DeviceConnection{Key: phoneKey, UpdatedAt: time.Now()}
	emit(Event{Kind: "phone_state", Session: 1, Connection: &older})
	wait(func() bool {
		return strings.Contains(textAt(child(idPhoneSettingsStatus)), "Update MicDrop on the phone")
	})
	if themeEnabled(child(idDeviceSettings)) || themeEnabled(child(idPhoneSettingsApply)) || themeEnabled(child(idPhoneSettingsReload)) {
		t.Fatal("an older phone's settings appeared editable")
	}
	minimum, maximum := 1000, 120000
	phoneSettings := &phonecontrol.Snapshot{Version: 1, Revision: strings.Repeat("a", 64), Enabled: true, Fields: []phonecontrol.Field{
		{Key: "live.audio_enabled", Label: "Play desktop audio", Group: "Live", Kind: "bool", Value: json.RawMessage("true"), Effect: "live"},
		{Key: "audio.fast_recovery", Label: "Fast buffer recovery", Group: "Audio", Kind: "bool", Value: json.RawMessage("true"), Effect: "next_connection"},
		{Key: "connection.recovery_ms", Label: "Recovery window (ms)", Group: "Advanced", Kind: "int", Value: json.RawMessage("90000"), Minimum: &minimum, Maximum: &maximum, Effect: "next_connection"},
	}}
	rtt, jitter, buffer, outputQueue := 8.0, 2.0, 60.0, 310.0
	phoneState := DeviceConnection{Key: phoneKey, UpdatedAt: time.Now(), MetricsAt: time.Now(), Settings: phoneSettings, SettingsSupported: true,
		Metrics: ConnectionMetrics{RTTMS: &rtt, JitterMS: &jitter, PlaybackBufferMS: &buffer, OutputQueueMS: &outputQueue}}
	emit(Event{Kind: "phone_state", Session: 1, Connection: &phoneState})
	wait(func() bool {
		return textAt(child(idDeviceCount)) == "1 device connected" && themeEnabled(child(idDeviceSettings))
	})
	// The editor left waiting loads the first snapshot itself; nothing changed, so no Reload prompt.
	wait(func() bool {
		status := textAt(child(idPhoneSettingsStatus))
		return checked(child(idPhoneFieldBool)) && themeEnabled(child(idPhoneSettingsApply)) &&
			strings.Contains(status, "phone permissions stay on the phone") && !strings.Contains(status, "Reload")
	})
	if !strings.Contains(textAt(child(idDeviceMetrics)), "Network RTT 8 ms") {
		t.Fatal("connection statistics did not render with their measured meaning")
	}
	// Optional CI captures use only this fake backend and an owned test window.
	// No desktop screenshot, real device names, pairing keys or credentials.
	if target := os.Getenv("MICDROP_DESKTOP_PREVIEW_DIR"); target != "" {
		send(hwnd, wmShow, 0, 0)
		for _, page := range []struct {
			id   int
			name string
		}{{idAudio, "audio"}, {idConnection, "connection"}, {idPhones, "phones"}, {idOptions, "options"}, {idDeviceSettings, "device-settings"}} {
			send(hwnd, 0x111, uintptr(page.id), 0)
			var client rect
			getClientRect.Call(hwnd, uintptr(unsafe.Pointer(&client)))
			for _, id := range []int{idSave, idLogs, idExit, idMessage, idExpiry, idDeviceCount, idDeviceList, idDeviceMetrics, idDeviceSettings, idPhoneSettingsStatus} {
				var bounds rect
				user32.NewProc("GetWindowRect").Call(child(id), uintptr(unsafe.Pointer(&bounds)))
				user32.NewProc("MapWindowPoints").Call(0, hwnd, uintptr(unsafe.Pointer(&bounds)), 2)
				if bounds.Left < 0 || bounds.Top < 0 || bounds.Right > client.Right || bounds.Bottom > client.Bottom {
					t.Fatalf("control %d outside client area: %+v in %+v", id, bounds, client)
				}
			}
			if err := captureWindow(hwnd, target, page.name); err != nil {
				t.Error(err)
			}
		}
	}
	// Applying a setting targets the selected authenticated device and the exact
	// snapshot shown by the editor. A phone-side change must require Reload.
	send(hwnd, 0x111, uintptr(idDeviceSettings), 0)
	if !checked(child(idPhoneFieldBool)) || !themeEnabled(child(idPhoneSettingsApply)) {
		t.Fatal("live phone setting did not load")
	}
	if status := textAt(child(idPhoneSettingsStatus)); !strings.Contains(status, "phone permissions stay on the phone") || strings.Contains(status, "Android") {
		t.Fatal("platform-specific editor guidance", status)
	}
	send(child(idPhoneFieldBool), 0xF5, 0, 0)
	send(hwnd, 0x111, uintptr(idPhoneSettingsApply), 0)
	select {
	case command := <-phoneEdits:
		if command.Value != phoneKey || command.Session != 1 || command.Settings == nil || command.Settings.BaseRevision != phoneSettings.Revision || string(command.Settings.Changes["live.audio_enabled"]) != "false" {
			t.Fatalf("wrong selected-device update: %+v", command)
		}
	case <-time.After(5 * time.Second):
		t.Fatal("device setting did not reach the host")
	}
	phoneSettings = phonecontrol.CloneSnapshot(phoneSettings)
	phoneSettings.Revision = strings.Repeat("b", 64)
	phoneSettings.Fields[0].Value = json.RawMessage("false")
	phoneSettings.Ack = &phonecontrol.Ack{ID: strings.Repeat("c", 32), Status: "applied", Message: "Setting applied on the phone."}
	phoneState.Settings, phoneState.UpdatedAt, phoneState.SettingsMessage = phoneSettings, time.Now(), "Setting applied on the phone."
	emit(Event{Kind: "phone_state", Session: 1, Connection: &phoneState})
	wait(func() bool { return !checked(child(idPhoneFieldBool)) && themeEnabled(child(idPhoneSettingsApply)) })
	phoneSettings = phonecontrol.CloneSnapshot(phoneSettings)
	phoneSettings.Revision = strings.Repeat("d", 64)
	phoneSettings.Fields[0].Value = json.RawMessage("true")
	phoneState.Settings, phoneState.UpdatedAt = phoneSettings, time.Now()
	emit(Event{Kind: "phone_state", Session: 1, Connection: &phoneState})
	wait(func() bool {
		return !themeEnabled(child(idPhoneSettingsApply)) && strings.Contains(textAt(child(idPhoneSettingsStatus)), "Reload")
	})
	send(hwnd, 0x111, uintptr(idPhoneSettingsReload), 0)
	if !checked(child(idPhoneFieldBool)) || !themeEnabled(child(idPhoneSettingsApply)) {
		t.Fatal("Reload did not recover from a concurrent phone edit")
	}
	phoneSettings = phonecontrol.CloneSnapshot(phoneSettings)
	phoneSettings.Enabled = false
	phoneSettings.Revision = strings.Repeat("e", 64)
	phoneState.Settings, phoneState.UpdatedAt = phoneSettings, time.Now()
	emit(Event{Kind: "phone_state", Session: 1, Connection: &phoneState})
	wait(func() bool {
		return strings.Contains(textAt(child(idPhoneSettingsStatus)), "Allow Windows") && !themeEnabled(child(idPhoneSettingsApply))
	})
	phoneSettings = phonecontrol.CloneSnapshot(phoneSettings)
	phoneSettings.Enabled = true
	phoneSettings.Revision = strings.Repeat("f", 64)
	phoneState.Settings, phoneState.UpdatedAt = phoneSettings, time.Now()
	emit(Event{Kind: "phone_state", Session: 1, Connection: &phoneState})
	wait(func() bool { return strings.Contains(textAt(child(idPhoneSettingsStatus)), "Reload") })
	send(hwnd, 0x111, uintptr(idPhoneSettingsReload), 0)
	emit(Event{Kind: "session_end", Session: 1, Message: "receiver_pause"})
	wait(func() bool {
		return strings.Contains(textAt(child(idDeviceCount)), "0 devices connected") && strings.Contains(textAt(child(idDeviceMetrics)), "last reported") &&
			strings.Contains(textAt(child(idPhoneSettingsStatus)), "Resume or reconnect it")
	})
	if themeEnabled(child(idDeviceSettings)) || themeEnabled(child(idPhoneSettingsApply)) {
		t.Fatal("paused phone controls remained available")
	}
	emit(Event{Kind: "session_begin", Session: 2, PhoneKey: phoneKey, Resuming: true})
	emit(Event{Kind: "session_status", Session: 2, State: "connected"})
	phoneState.UpdatedAt = time.Now()
	emit(Event{Kind: "phone_state", Session: 2, Connection: &phoneState})
	wait(func() bool {
		return strings.Contains(textAt(child(idPhoneSettingsStatus)), "Reload") && !themeEnabled(child(idPhoneSettingsApply))
	})
	send(hwnd, 0x111, uintptr(idPhoneSettingsReload), 0)
	if !themeEnabled(child(idPhoneSettingsApply)) {
		t.Fatal("explicit reload did not rebind editor after same-phone resume")
	}
	send(hwnd, 0x111, uintptr(idStop), 0)
	select {
	case <-hostDone:
	case <-time.After(5 * time.Second):
		t.Fatal("Stop did not cancel host")
	}
	wait(func() bool { return textAt(child(idStatus)) == "Stopped" })
	if enabled, _, _ := user32.NewProc("IsWindowEnabled").Call(child(idCopy)); enabled != 0 {
		t.Fatal("stopped invitation remains copyable")
	}
	if enabled, _, _ := user32.NewProc("IsWindowEnabled").Call(child(idCapture)); enabled == 0 {
		t.Fatal("settings still disabled after cleanup")
	}
	portStyle, _, _ = user32.NewProc("GetWindowLongPtrW").Call(child(idPort), ^uintptr(15))
	if portStyle&0x800 != 0 {
		t.Fatal("port remains read-only after cleanup")
	}
	send(hwnd, 0x111, uintptr(idOptions), 0)
	send(child(idNotifications), 0xF5, 0, 0) // Native BM_CLICK must still toggle.
	if !checked(child(idNotifications)) {
		t.Fatal("flat checkbox lost native checked state")
	}
	send(child(idNotifications), 0xF5, 0, 0)
	if checked(child(idNotifications)) {
		t.Fatal("flat checkbox cannot be cleared")
	}
	if !checked(child(idSaveLogs)) {
		t.Fatal("logging did not default on")
	}
	setText(child(idLogRetention), "3")
	send(child(idSaveLogs), 0xF5, 0, 0)
	send(hwnd, 0x111, uintptr(idSave), 0)
	saved, err := LoadSettings(directory)
	if err != nil || saved.SaveLogs || saved.LogRetention != 3 {
		t.Fatal(saved, err)
	}
}

func captureWindow(hwnd uintptr, directory, name string) error {
	var area rect
	user32.NewProc("GetWindowRect").Call(hwnd, uintptr(unsafe.Pointer(&area)))
	width, height := int(area.Right-area.Left), int(area.Bottom-area.Top)
	if width < 1 || height < 1 || width > 4096 || height > 4096 {
		return fmt.Errorf("invalid capture dimensions %dx%d", width, height)
	}
	dc, _, _ := gdi32.NewProc("CreateCompatibleDC").Call(0)
	if dc == 0 {
		return fmt.Errorf("cannot create capture DC")
	}
	defer gdi32.NewProc("DeleteDC").Call(dc)
	var info struct {
		Size                   uint32
		Width, Height          int32
		Planes, BitCount       uint16
		Compression, ImageSize uint32
		X, Y                   int32
		Colors, Important      uint32
	}
	info.Size = 40
	info.Width = int32(width)
	info.Height = -int32(height)
	info.Planes = 1
	info.BitCount = 32
	var pixels unsafe.Pointer
	bitmap, _, _ := gdi32.NewProc("CreateDIBSection").Call(dc, uintptr(unsafe.Pointer(&info)), 0, uintptr(unsafe.Pointer(&pixels)), 0, 0)
	if bitmap == 0 || pixels == nil {
		return fmt.Errorf("cannot create capture bitmap")
	}
	defer deleteObject.Call(bitmap)
	old, _, _ := gdi32.NewProc("SelectObject").Call(dc, bitmap)
	defer gdi32.NewProc("SelectObject").Call(dc, old)
	// Service-session PrintWindow returns an empty compositor surface. Render
	// only our native controls through WM_PRINT instead, using window coordinates
	// for children/nonclient and the client origin for our background callback.
	// This is a control render, not a capture of the user's interactive desktop.
	var origin point
	user32.NewProc("ClientToScreen").Call(hwnd, uintptr(unsafe.Pointer(&origin)))
	saved, _, _ := gdi32.NewProc("SaveDC").Call(dc)
	gdi32.NewProc("SetViewportOrgEx").Call(dc, uintptr(origin.X-area.Left), uintptr(origin.Y-area.Top), 0)
	send(hwnd, 0x14, dc, 0) // WM_ERASEBKGND in client coordinates.
	gdi32.NewProc("RestoreDC").Call(dc, saved)
	send(hwnd, 0x317, dc, 2|4|16) // WM_PRINT: nonclient, client, children.
	gdi32.NewProc("GdiFlush").Call()
	raw := unsafe.Slice((*byte)(pixels), width*height*4)
	img := image.NewNRGBA(image.Rect(0, 0, width, height))
	colors := make(map[uint32]struct{})
	for i := 0; i < len(raw); i += 4 {
		img.Pix[i] = raw[i+2]
		img.Pix[i+1] = raw[i+1]
		img.Pix[i+2] = raw[i]
		img.Pix[i+3] = 255
		if len(colors) < 16 {
			colors[uint32(raw[i])|uint32(raw[i+1])<<8|uint32(raw[i+2])<<16] = struct{}{}
		}
	}
	if len(colors) < 8 {
		return fmt.Errorf("%s native preview is blank or missing controls (%d colors)", name, len(colors))
	}
	var encoded bytes.Buffer
	if err := png.Encode(&encoded, img); err != nil {
		return err
	}
	if err := os.MkdirAll(directory, 0700); err != nil {
		return err
	}
	if err := os.WriteFile(filepath.Join(directory, name+".png"), encoded.Bytes(), 0600); err != nil {
		return err
	}
	// Emit the small synthetic preview to test output so CI logs retain a copy
	// alongside optional artifact uploads.
	fmt.Printf("MICDROP_UI_PREVIEW %s %s\n", name, base64.StdEncoding.EncodeToString(encoded.Bytes()))
	return nil
}

//go:noinline
func growWinTestStack(depth int) byte {
	var pad [4096]byte
	pad[0] = byte(depth)
	pad[len(pad)-1] = byte(depth >> 8)
	if depth > 0 {
		pad[1] = growWinTestStack(depth - 1)
	}
	return pad[0] ^ pad[1] ^ pad[len(pad)-1]
}

func TestWindowsSendPointerAndTextPreserveGCLifetime(t *testing.T) {
	runtime.LockOSThread()
	defer runtime.UnlockOSThread()

	const (
		msgReadText = 0x8055
		msgWriteBuf = 0x8056
		hwndMessage = ^uintptr(2) // HWND_MESSAGE ((HWND)-3)
	)

	lstrlenW := kernel32.NewProc("lstrlenW")
	var observedText string
	var sink byte
	wndProc := windows.NewCallback(func(hwnd uintptr, message uint32, wparam, lparam uintptr) uintptr {
		switch message {
		case msgReadText:
			sink ^= growWinTestStack(48)
			for i := 0; i < 64; i++ {
				churn := make([]uint16, 128)
				for j := range churn {
					churn[j] = 0xDEAD
				}
				sink ^= byte(churn[0])
			}
			runtime.GC()
			debug.FreeOSMemory()
			runtime.GC()
			n, _, _ := lstrlenW.Call(lparam)
			units := make([]uint16, int(n)+1)
			if n > 0 {
				moveMemory.Call(uintptr(unsafe.Pointer(&units[0])), lparam, n*2)
				runtime.KeepAlive(units)
			}
			observedText = windows.UTF16ToString(units)
			return uintptr(len(observedText))
		case msgWriteBuf:
			sink ^= growWinTestStack(48)
			runtime.GC()
			debug.FreeOSMemory()
			runtime.GC()
			encoded := utf16.Encode([]rune("Returned item text after GC + stack growth\x00"))
			count := min(len(encoded), int(wparam))
			if count > 0 {
				moveMemory.Call(lparam, uintptr(unsafe.Pointer(&encoded[0])), uintptr(count)*2)
				runtime.KeepAlive(encoded)
			}
			return uintptr(len(encoded) - 1)
		}
		r, _, _ := defWindowProc.Call(hwnd, uintptr(message), wparam, lparam)
		return r
	})

	var instance windows.Handle
	if err := windows.GetModuleHandleEx(2, nil, &instance); err != nil {
		t.Fatal(err)
	}
	className := wide(fmt.Sprintf("MicDrop.GC.Test.%d.%d", os.Getpid(), time.Now().UnixNano()))
	wc := windowClass{Proc: wndProc, Instance: uintptr(instance), ClassName: className}
	wc.Size = uint32(unsafe.Sizeof(wc))
	atom, _, err := registerClass.Call(uintptr(unsafe.Pointer(&wc)))
	runtime.KeepAlive(&wc)
	if atom == 0 {
		t.Fatalf("register test class: %v", err)
	}
	defer func() {
		unregisterClass.Call(uintptr(unsafe.Pointer(className)), uintptr(instance))
		runtime.KeepAlive(className)
	}()

	hwnd, _, err := createWindow.Call(0, uintptr(unsafe.Pointer(className)), uintptr(unsafe.Pointer(className)), 0, 0, 0, 0, 0, hwndMessage, 0, uintptr(instance), 0)
	runtime.KeepAlive(className)
	if hwnd == 0 {
		t.Fatalf("create message-only window: %v", err)
	}
	defer destroyWindow.Call(hwnd)

	for i := 0; i < 40; i++ {
		want := fmt.Sprintf("Dynamic audio endpoint #%d — CABLE Input (VB-Audio Virtual Cable)", i)
		if gotLen := int(sendText(hwnd, msgReadText, 0, want)); gotLen != len(want) || observedText != want {
			t.Fatalf("iter %d: sendText corrupted string during GC: got %q (len=%d), want %q", i, observedText, gotLen, want)
		}

		buf := make([]uint16, 64)
		if n := int32(sendPointer(hwnd, msgWriteBuf, uintptr(len(buf)), &buf[0])); n <= 0 {
			t.Fatalf("iter %d: sendPointer returned %d", i, n)
		}
		if got := windows.UTF16ToString(buf); got != "Returned item text after GC + stack growth" {
			t.Fatalf("iter %d: sendPointer buffer mismatch: got %q", i, got)
		}
	}
	runtime.KeepAlive(sink)
}
