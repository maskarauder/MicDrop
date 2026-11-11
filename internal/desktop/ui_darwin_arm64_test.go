// SPDX-License-Identifier: MPL-2.0
//go:build darwin && arm64

package desktop

import (
	"context"
	"encoding/json"
	"image/png"
	"os"
	"os/signal"
	"path/filepath"
	"runtime"
	"strings"
	"syscall"
	"testing"
	"time"

	"github.com/maskarauder/MicDrop/internal/phonecontrol"
)

var darwinMainThread = make(chan func(), 4)

func init() {
	runtime.LockOSThread()
}

func TestMain(m *testing.M) {
	done := make(chan int, 1)
	go func() {
		done <- m.Run()
	}()
	for {
		select {
		case fn := <-darwinMainThread:
			fn()
		case code := <-done:
			os.Exit(code)
		}
	}
}

func TestDarwinSingleInstanceLock(t *testing.T) {
	sigCh := make(chan os.Signal, 2)
	signal.Notify(sigCh, syscall.SIGUSR1)
	defer signal.Stop(sigCh)

	dir := t.TempDir()
	lockFile, already, err := acquireInstanceLock(dir)
	if err != nil || already || lockFile == nil {
		t.Fatalf("first lock failed: already=%v err=%v", already, err)
	}
	defer func() {
		_ = syscall.Flock(int(lockFile.Fd()), syscall.LOCK_UN)
		_ = lockFile.Close()
	}()

	secondFile, secondAlready, err := acquireInstanceLock(dir)
	if err != nil || !secondAlready || secondFile != nil {
		t.Fatalf("second lock did not detect active instance: already=%v err=%v", secondAlready, err)
	}
	select {
	case <-sigCh:
	case <-time.After(2 * time.Second):
		t.Fatal("second instance did not signal primary instance")
	}
}

func TestDarwinDesktopControls(t *testing.T) {
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
			return []AudioDevice{
				{ID: "speaker", Name: "MacBook Pro Speakers (test fixture)", Default: true},
				{ID: "cable", Name: "BlackHole 2ch (test fixture)"},
			}, nil
		},
		RemoteStatus: func() (string, error) { return "No remote configuration imported", nil },
	}

	directory := t.TempDir()
	settings := Defaults()
	settings.Notifications = false
	settings.Remote = true
	if err := SaveSettings(directory, settings); err != nil {
		t.Fatal(err)
	}

	darwinMainThread <- func() {
		finished <- runWindow(backend, directory, true, true)
	}

	var emit func(Event)
	select {
	case emit = <-started:
	case err := <-finished:
		t.Fatalf("macOS desktop window did not start: %v", err)
	case <-time.After(10 * time.Second):
		t.Fatal("macOS desktop window startup timed out")
	}

	uiDo := func(fn func()) {
		done := make(chan struct{})
		uiTestQueue <- func() {
			fn()
			close(done)
		}
		wakeTestQueue()
		select {
		case <-done:
		case <-time.After(5 * time.Second):
			t.Fatal("timed out dispatching onto AppKit main thread")
		}
	}
	uiRead := func(id int) string {
		var out string
		uiDo(func() { out = uiTextAt(id) })
		return out
	}
	uiEnabledAt := func(id int) bool {
		var out bool
		uiDo(func() { out = uiIsEnabled(id) })
		return out
	}
	uiCheckedAt := func(id int) bool {
		var out bool
		uiDo(func() { out = uiChecked(id) })
		return out
	}
	uiReadOnlyAt := func(id int) bool {
		var out bool
		uiDo(func() { out = uiIsReadOnly(id) })
		return out
	}
	uiClick := func(id int) {
		uiDo(func() { triggerControlForTest(id, 0) })
	}

	defer func() {
		uiDo(func() { triggerControlForTest(idExit, 0) })
		select {
		case err := <-finished:
			if err != nil {
				t.Error(err)
			}
		case <-time.After(10 * time.Second):
			t.Error("macOS desktop Quit did not finish cleanup")
		}
	}()

	wait := func(condition func() bool) {
		t.Helper()
		deadline := time.Now().Add(5 * time.Second)
		for !condition() {
			if time.Now().After(deadline) {
				t.Fatal("macOS UI did not reach expected state")
			}
			time.Sleep(20 * time.Millisecond)
		}
	}

	wait(func() bool { return uiRead(idStatus) == "Ready for a paired phone" })
	wait(func() bool {
		var count int
		uiDo(func() { count = popupCountForTest(idCapture) })
		return count > 0
	})

	var capSel, micSel, cableIdx int
	uiDo(func() {
		capSel = uiComboSelected(idCapture)
		micSel = uiComboSelected(idMicrophone)
		cableIdx = popupFindExactForTest(idCapture, "BlackHole 2ch (test fixture)")
	})
	if capSel != 0 || micSel != 0 {
		t.Fatalf("initial audio selections wrong: cap=%d mic=%d", capSel, micSel)
	}
	if cableIdx != 2 {
		t.Fatalf("expected virtual cable at index 2, got %d", cableIdx)
	}
	if uiEnabledAt(idCapture) {
		t.Fatal("capture selection editable while running")
	}
	if !uiReadOnlyAt(idPort) {
		t.Fatal("port must stay read-only while running")
	}

	uiClick(idPhones)
	uiClick(idPair)
	wait(func() bool { return uiRead(idExpiry) != "Pairing is closed." })

	phoneKey := strings.Repeat("1", 64)
	otherKey := strings.Repeat("2", 64)
	emit(Event{Kind: "phones", Phones: []Phone{{Name: "iPhone 16 (test)", Key: phoneKey}, {Name: "Second phone (test)", Key: otherKey}}})
	emit(Event{Kind: "session_begin", Session: 1, PhoneKey: phoneKey})
	emit(Event{Kind: "session_status", Session: 1, State: "connected"})
	wait(func() bool { return uiRead(idStatus) == "Phone connected" })

	waiting := DeviceConnection{Key: phoneKey, UpdatedAt: time.Now(), SettingsSupported: true}
	emit(Event{Kind: "phone_state", Session: 1, Connection: &waiting})
	uiDo(func() { triggerControlForTest(idDeviceList, 2) }) // Double-click opens Phone settings.
	wait(func() bool {
		return strings.Contains(uiRead(idPhoneSettingsStatus), "Waiting for the phone to share")
	})

	older := DeviceConnection{Key: phoneKey, UpdatedAt: time.Now()}
	emit(Event{Kind: "phone_state", Session: 1, Connection: &older})
	wait(func() bool {
		return strings.Contains(uiRead(idPhoneSettingsStatus), "Update MicDrop on the phone")
	})
	if uiEnabledAt(idDeviceSettings) || uiEnabledAt(idPhoneSettingsApply) || uiEnabledAt(idPhoneSettingsReload) {
		t.Fatal("an older phone's settings appeared editable")
	}

	minimum, maximum := 1000, 120000
	phoneSettings := &phonecontrol.Snapshot{
		Version:  1,
		Revision: strings.Repeat("a", 64),
		Enabled:  true,
		Fields: []phonecontrol.Field{
			{Key: "live.audio_enabled", Label: "Play desktop audio", Group: "Live", Kind: "bool", Value: json.RawMessage("true"), Effect: "live"},
			{Key: "audio.fast_recovery", Label: "Fast buffer recovery", Group: "Audio", Kind: "bool", Value: json.RawMessage("true"), Effect: "next_connection"},
			{Key: "connection.recovery_ms", Label: "Recovery window (ms)", Group: "Advanced", Kind: "int", Value: json.RawMessage("90000"), Minimum: &minimum, Maximum: &maximum, Effect: "next_connection"},
		},
	}
	rtt, jitter, buffer, outputQueue := 8.0, 2.0, 60.0, 310.0
	phoneState := DeviceConnection{
		Key:               phoneKey,
		UpdatedAt:         time.Now(),
		MetricsAt:         time.Now(),
		Settings:          phoneSettings,
		SettingsSupported: true,
		Metrics:           ConnectionMetrics{RTTMS: &rtt, JitterMS: &jitter, PlaybackBufferMS: &buffer, OutputQueueMS: &outputQueue},
	}
	emit(Event{Kind: "phone_state", Session: 1, Connection: &phoneState})
	wait(func() bool {
		return uiRead(idDeviceCount) == "1 device connected" && uiEnabledAt(idDeviceSettings)
	})
	wait(func() bool {
		status := uiRead(idPhoneSettingsStatus)
		return uiCheckedAt(idPhoneFieldBool) && uiEnabledAt(idPhoneSettingsApply) &&
			strings.Contains(status, "phone permissions stay on the phone") && !strings.Contains(status, "Reload")
	})
	if !strings.Contains(uiRead(idDeviceMetrics), "Network RTT 8 ms") {
		t.Fatal("connection statistics did not render with their measured meaning")
	}

	// Verify all primary controls lie strictly inside contentView bounds across every page.
	previewDir := os.Getenv("MICDROP_DESKTOP_PREVIEW_DIR")
	for _, page := range []struct {
		id   int
		name string
	}{
		{idAudio, "audio"},
		{idConnection, "connection"},
		{idPhones, "phones"},
		{idOptions, "options"},
		{idDeviceSettings, "device-settings"},
	} {
		uiClick(page.id)
		for _, id := range []int{idSave, idLogs, idExit, idMessage, idExpiry, idDeviceCount, idDeviceList, idDeviceMetrics, idDeviceSettings, idPhoneSettingsStatus} {
			var x, y, w, h, winW, winH int
			var ok bool
			uiDo(func() {
				ok, x, y, w, h, winW, winH = controlBoundsForTest(id)
			})
			if !ok || x < 0 || y < 0 || x+w > winW || y+h > winH {
				t.Fatalf("control %d outside client bounds on %s: (%d,%d,%d,%d) in %dx%d", id, page.name, x, y, w, h, winW, winH)
			}
		}
		if previewDir != "" {
			if err := os.MkdirAll(previewDir, 0700); err != nil {
				t.Fatal(err)
			}
			pngPath := filepath.Join(previewDir, page.name+".png")
			var captured bool
			uiDo(func() { captured = capturePNGForTest(pngPath) })
			if !captured {
				t.Fatalf("failed to capture preview %s", pngPath)
			}
			f, err := os.Open(pngPath)
			if err != nil {
				t.Fatal(err)
			}
			img, err := png.Decode(f)
			_ = f.Close()
			if err != nil || img.Bounds().Dx() < 860 || img.Bounds().Dy() < 700 {
				t.Fatalf("invalid preview PNG %s: %v", pngPath, err)
			}
		}
	}

	uiClick(idDeviceSettings)
	if !uiCheckedAt(idPhoneFieldBool) || !uiEnabledAt(idPhoneSettingsApply) {
		t.Fatal("live phone setting did not load")
	}
	uiClick(idPhoneFieldBool)
	uiClick(idPhoneSettingsApply)
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
	wait(func() bool { return !uiCheckedAt(idPhoneFieldBool) && uiEnabledAt(idPhoneSettingsApply) })

	phoneSettings = phonecontrol.CloneSnapshot(phoneSettings)
	phoneSettings.Revision = strings.Repeat("d", 64)
	phoneSettings.Fields[0].Value = json.RawMessage("true")
	phoneState.Settings, phoneState.UpdatedAt = phoneSettings, time.Now()
	emit(Event{Kind: "phone_state", Session: 1, Connection: &phoneState})
	wait(func() bool {
		return !uiEnabledAt(idPhoneSettingsApply) && strings.Contains(uiRead(idPhoneSettingsStatus), "Reload")
	})

	uiClick(idPhoneSettingsReload)
	if !uiCheckedAt(idPhoneFieldBool) || !uiEnabledAt(idPhoneSettingsApply) {
		t.Fatal("Reload did not recover from a concurrent phone edit")
	}

	phoneSettings = phonecontrol.CloneSnapshot(phoneSettings)
	phoneSettings.Enabled = false
	phoneSettings.Revision = strings.Repeat("e", 64)
	phoneState.Settings, phoneState.UpdatedAt = phoneSettings, time.Now()
	emit(Event{Kind: "phone_state", Session: 1, Connection: &phoneState})
	wait(func() bool {
		return strings.Contains(uiRead(idPhoneSettingsStatus), "Allow Windows") && !uiEnabledAt(idPhoneSettingsApply)
	})

	phoneSettings = phonecontrol.CloneSnapshot(phoneSettings)
	phoneSettings.Enabled = true
	phoneSettings.Revision = strings.Repeat("f", 64)
	phoneState.Settings, phoneState.UpdatedAt = phoneSettings, time.Now()
	emit(Event{Kind: "phone_state", Session: 1, Connection: &phoneState})
	wait(func() bool { return strings.Contains(uiRead(idPhoneSettingsStatus), "Reload") })
	uiClick(idPhoneSettingsReload)

	emit(Event{Kind: "session_end", Session: 1, Message: "receiver_pause"})
	wait(func() bool {
		return strings.Contains(uiRead(idDeviceCount), "0 devices connected") &&
			strings.Contains(uiRead(idDeviceMetrics), "last reported") &&
			strings.Contains(uiRead(idPhoneSettingsStatus), "Resume or reconnect it")
	})
	if uiEnabledAt(idDeviceSettings) || uiEnabledAt(idPhoneSettingsApply) {
		t.Fatal("paused phone controls remained available")
	}

	emit(Event{Kind: "session_begin", Session: 2, PhoneKey: phoneKey, Resuming: true})
	emit(Event{Kind: "session_status", Session: 2, State: "connected"})
	phoneState.UpdatedAt = time.Now()
	emit(Event{Kind: "phone_state", Session: 2, Connection: &phoneState})
	wait(func() bool {
		return strings.Contains(uiRead(idPhoneSettingsStatus), "Reload") && !uiEnabledAt(idPhoneSettingsApply)
	})
	uiClick(idPhoneSettingsReload)
	if !uiEnabledAt(idPhoneSettingsApply) {
		t.Fatal("explicit reload did not rebind editor after same-phone resume")
	}

	uiClick(idStop)
	select {
	case <-hostDone:
	case <-time.After(5 * time.Second):
		t.Fatal("Stop did not cancel host")
	}
	wait(func() bool { return uiRead(idStatus) == "Stopped" })
	if uiEnabledAt(idCopy) {
		t.Fatal("stopped invitation remains copyable")
	}
	if !uiEnabledAt(idCapture) {
		t.Fatal("settings still disabled after cleanup")
	}
	if uiReadOnlyAt(idPort) {
		t.Fatal("port remains read-only after cleanup")
	}

	uiClick(idOptions)
	uiClick(idNotifications)
	if !uiCheckedAt(idNotifications) {
		t.Fatal("checkbox did not toggle on")
	}
	uiClick(idNotifications)
	if uiCheckedAt(idNotifications) {
		t.Fatal("checkbox did not toggle off")
	}
	if !uiCheckedAt(idSaveLogs) {
		t.Fatal("logging did not default on")
	}
	uiDo(func() { uiSetText(idLogRetention, "3") })
	uiClick(idSaveLogs)
	uiClick(idSave)
	saved, err := LoadSettings(directory)
	if err != nil || saved.SaveLogs || saved.LogRetention != 3 {
		t.Fatalf("unexpected saved settings: %+v err=%v", saved, err)
	}
}
