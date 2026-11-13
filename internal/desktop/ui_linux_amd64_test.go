// SPDX-License-Identifier: MPL-2.0
//go:build linux && amd64

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

var linuxMainThread = make(chan func(), 4)

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
		case fn := <-linuxMainThread:
			fn()
		case code := <-done:
			os.Exit(code)
		}
	}
}

func hasLinuxDisplay() bool {
	return strings.TrimSpace(os.Getenv("DISPLAY")) != "" || strings.TrimSpace(os.Getenv("WAYLAND_DISPLAY")) != ""
}

func TestLinuxSingleInstanceLock(t *testing.T) {
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

func TestLinuxDesktopMissingDisplayFailsCleanly(t *testing.T) {
	t.Setenv("DISPLAY", "")
	t.Setenv("WAYLAND_DISPLAY", "")

	dir := t.TempDir()
	finished := make(chan error, 1)
	linuxMainThread <- func() {
		finished <- runWindow(Backend{}, dir, false, true)
	}
	select {
	case err := <-finished:
		if err == nil || !strings.Contains(err.Error(), "Wayland or X11 display") {
			t.Fatalf("expected clean missing-display error, got %v", err)
		}
	case <-time.After(5 * time.Second):
		t.Fatal("missing-display check hung")
	}

	lockFile, already, err := acquireInstanceLock(dir)
	if err != nil || already || lockFile == nil {
		t.Fatalf("instance lock was not released on failed display init: already=%v err=%v", already, err)
	}
	_ = syscall.Flock(int(lockFile.Fd()), syscall.LOCK_UN)
	_ = lockFile.Close()
}

func TestLinuxDesktopControls(t *testing.T) {
	if !hasLinuxDisplay() {
		if strings.TrimSpace(os.Getenv("MICDROP_DESKTOP_PREVIEW_DIR")) != "" {
			t.Fatal("MICDROP_DESKTOP_PREVIEW_DIR is set, but neither DISPLAY nor WAYLAND_DISPLAY is active")
		}
		t.Skip("Linux GUI test requires DISPLAY or WAYLAND_DISPLAY (run under xvfb-run on headless machines)")
	}

	xdgConfig := filepath.Join(t.TempDir(), "xdg-config")
	t.Setenv("XDG_CONFIG_HOME", xdgConfig)

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
				{ID: "speaker", Name: "PipeWire Built-in Audio Analog Stereo (test fixture)", Default: true},
				{ID: "cable", Name: "MicDropCable Virtual Sink (test fixture)"},
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

	linuxMainThread <- func() {
		finished <- runWindow(backend, directory, true, true)
	}

	var emit func(Event)
	select {
	case emit = <-started:
	case err := <-finished:
		t.Fatalf("Linux desktop window did not start: %v", err)
	case <-time.After(10 * time.Second):
		t.Fatal("Linux desktop window startup timed out")
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
			t.Fatal("timed out dispatching onto GTK main thread")
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
			t.Error("Linux desktop Quit did not finish cleanup")
		}
	}()

	wait := func(condition func() bool) {
		t.Helper()
		deadline := time.Now().Add(5 * time.Second)
		for !condition() {
			if time.Now().After(deadline) {
				t.Fatal("Linux UI did not reach expected state")
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

	var capSel, micSel, cableIdx, defaultIdx int
	uiDo(func() {
		capSel = uiComboSelected(idCapture)
		micSel = uiComboSelected(idMicrophone)
		defaultIdx = popupFindExactForTest(idCapture, "Default Linux output")
		cableIdx = popupFindExactForTest(idCapture, "MicDropCable Virtual Sink (test fixture)")
	})
	if capSel != 0 || micSel != 0 || defaultIdx != 0 {
		t.Fatalf("initial audio selections wrong: cap=%d mic=%d defaultIdx=%d", capSel, micSel, defaultIdx)
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
	emit(Event{Kind: "phones", Phones: []Phone{{Name: "Pixel 9 Pro (test)", Key: phoneKey}, {Name: "Second phone (test)", Key: otherKey}}})
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

	// Verify all primary controls lie strictly inside root bounds and do not overlap per page.
	headerFooterIDs := []int{
		idTitle, idStatus, idDeviceCount, idDeviceList, idDeviceMetrics,
		idStart, idStop, idDeviceSettings,
		idAudio, idConnection, idPhones, idOptions,
		idMessage, idSave, idLogs, idExit,
	}
	previewDir := os.Getenv("MICDROP_DESKTOP_PREVIEW_DIR")
	for _, page := range []struct {
		id       int
		name     string
		controls []int
	}{
		{idAudio, "audio", []int{idCapture, idMicrophone, idRefreshAudio, idCableHelp}},
		{idConnection, "connection", []int{idNetwork, idRefreshNetwork, idPort, idRemote, idRemoteStatus, idImport, idForget, idFirewall}},
		{idPhones, "phones", []int{idPhoneList, idRemove, idPair, idPending, idApprove, idReject, idQR, idCopy, idExpiry}},
		{idOptions, "options", []int{idStartup, idNotifications, idSaveLogs, idLogRetention}},
		{idDeviceSettings, "device-settings", []int{idPhoneSettingsTitle, idPhoneSettingsGroup, idPhoneSettingsBack, idPhoneSettingsList, idPhoneFieldLabel, idPhoneFieldBool, idPhoneFieldEffect, idPhoneSettingsApply, idPhoneSettingsReload, idPhoneSettingsStatus}},
	} {
		uiClick(page.id)
		type rect struct{ id, x, y, w, h int }
		var rects []rect
		allIDs := append(append([]int(nil), headerFooterIDs...), page.controls...)
		for _, id := range allIDs {
			var x, y, w, h, winW, winH int
			var ok bool
			uiDo(func() {
				ok, x, y, w, h, winW, winH = controlBoundsForTest(id)
			})
			if !ok || w <= 0 || h <= 0 || x < 0 || y < 0 || x+w > winW || y+h > winH {
				t.Fatalf("control %d outside client bounds on %s: (%d,%d,%d,%d) in %dx%d", id, page.name, x, y, w, h, winW, winH)
			}
			rects = append(rects, rect{id, x, y, w, h})
		}
		for i := 0; i < len(rects); i++ {
			for j := i + 1; j < len(rects); j++ {
				a, b := rects[i], rects[j]
				if a.x < b.x+b.w && a.x+a.w > b.x && a.y < b.y+b.h && a.y+a.h > b.y {
					t.Fatalf("controls %d (%d,%d,%d,%d) and %d (%d,%d,%d,%d) overlap on %s",
						a.id, a.x, a.y, a.w, a.h, b.id, b.x, b.y, b.w, b.h, page.name)
				}
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
	if nets, err := Networks(); err == nil && len(nets) > 0 {
		uiDo(func() {
			if activeWindow != nil && len(activeWindow.networks) > 1 {
				labels := []string{"Choose your home LAN adapter"}
				for _, n := range activeWindow.networks[1:] {
					labels = append(labels, n.Label())
				}
				uiComboItems(idNetwork, labels, 1)
			}
		})
		uiClick(idStartup)
		if !uiCheckedAt(idStartup) {
			t.Fatal("XDG autostart checkbox did not enable")
		}
		autostartFile := filepath.Join(xdgConfig, "autostart", "micdrop.desktop")
		if _, err := os.Stat(autostartFile); err != nil {
			t.Fatalf("expected XDG autostart file %s: %v", autostartFile, err)
		}
		uiClick(idStartup)
		if uiCheckedAt(idStartup) {
			t.Fatal("XDG autostart checkbox did not disable")
		}
		if _, err := os.Stat(autostartFile); !os.IsNotExist(err) {
			t.Fatalf("expected XDG autostart file removal, got %v", err)
		}
	}

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

func TestLinuxDesktopGracefulQuitWaitsForControllerStop(t *testing.T) {
	if !hasLinuxDisplay() {
		t.Skip("Linux GUI test requires DISPLAY or WAYLAND_DISPLAY")
	}

	started := make(chan struct{}, 1)
	stopping := make(chan struct{}, 1)
	allowStop := make(chan struct{})
	finished := make(chan error, 1)

	backend := Backend{
		Run: func(ctx context.Context, _ Settings, _ <-chan Command, emit func(Event)) error {
			emit(Event{Kind: "ready", Message: "LAN control ready (test host)"})
			started <- struct{}{}
			<-ctx.Done()
			stopping <- struct{}{}
			<-allowStop
			return nil
		},
		Devices: func() ([]AudioDevice, error) {
			return []AudioDevice{{ID: "speaker", Name: "PipeWire Output (test fixture)", Default: true}}, nil
		},
		RemoteStatus: func() (string, error) { return "No remote configuration imported", nil },
	}

	directory := t.TempDir()
	settings := Defaults()
	settings.Notifications = false
	if err := SaveSettings(directory, settings); err != nil {
		t.Fatal(err)
	}

	linuxMainThread <- func() {
		finished <- runWindow(backend, directory, true, true)
	}

	select {
	case <-started:
	case err := <-finished:
		t.Fatalf("Linux desktop window did not start: %v", err)
	case <-time.After(10 * time.Second):
		t.Fatal("Linux desktop startup timed out")
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
			t.Fatal("timed out dispatching onto GTK main thread")
		}
	}

	uiDo(func() {
		if activeWindow != nil {
			activeWindow.requestQuit.Store(true)
			activeWindow.tick()
		}
	})

	select {
	case <-stopping:
	case <-time.After(5 * time.Second):
		t.Fatal("graceful quit did not initiate controller stop")
	}

	select {
	case err := <-finished:
		t.Fatalf("runWindow exited before controller finished stopping: %v", err)
	case <-time.After(150 * time.Millisecond):
	}

	close(allowStop)
	select {
	case err := <-finished:
		if err != nil {
			t.Fatalf("unexpected error from runWindow: %v", err)
		}
	case <-time.After(10 * time.Second):
		t.Fatal("runWindow did not finish after controller stopped")
	}

	lockFile, already, err := acquireInstanceLock(directory)
	if err != nil || already || lockFile == nil {
		t.Fatalf("desktop.lock was not released after graceful quit: already=%v err=%v", already, err)
	}
	_ = syscall.Flock(int(lockFile.Fd()), syscall.LOCK_UN)
	_ = lockFile.Close()
}
