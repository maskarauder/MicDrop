// SPDX-License-Identifier: MPL-2.0
//go:build linux && amd64

package desktop

import (
	"bufio"
	"context"
	"encoding/json"
	"errors"
	"image/png"
	"io"
	"os"
	"os/exec"
	"os/signal"
	"path/filepath"
	"runtime"
	"strings"
	"sync/atomic"
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

func TestLinuxModalShutdownStateMachine(t *testing.T) {
	for _, trigger := range []string{"signal", "exit_action"} {
		for _, dialogCase := range []struct {
			name string
			open func(u *desktopWindow)
		}{
			{
				name: "help_info",
				open: func(u *desktopWindow) { u.action(idCableHelp) },
			},
			{
				name: "confirm_forget",
				open: func(u *desktopWindow) { u.action(idForget) },
			},
			{
				name: "confirm_approve",
				open: func(u *desktopWindow) { u.action(idApprove) },
			},
			{
				name: "file_import",
				open: func(u *desktopWindow) { u.action(idImport) },
			},
			{
				name: "error_dialog",
				open: func(u *desktopWindow) { u.showErr(errors.New("simulated failure")) },
			},
		} {
			t.Run(trigger+"_"+dialogCase.name, func(t *testing.T) {
				var imported, forgot, approved atomic.Bool
				var lockReleased atomic.Bool
				var cancelled atomic.Bool

				readyCh := make(chan func(Event), 1)
				backend := Backend{
					Run: func(ctx context.Context, _ Settings, commands <-chan Command, emit func(Event)) error {
						emit(Event{Kind: "ready", Message: "LAN control ready"})
						emit(Event{Kind: "invitation", Link: "micdrop://pair/v1/test-fixture", Expires: time.Now().Add(time.Minute)})
						emit(Event{Kind: "pending", Pending: Pending{ID: "req-123", Name: "Test Phone", Key: strings.Repeat("a", 64)}})
						readyCh <- emit
						for {
							select {
							case <-ctx.Done():
								return nil
							case cmd := <-commands:
								if cmd.Action == "approve" {
									approved.Store(true)
								}
							}
						}
					},
					ImportRemote: func(string) error {
						imported.Store(true)
						return nil
					},
					ForgetRemote: func() error {
						forgot.Store(true)
						return nil
					},
				}

				u := &desktopWindow{
					backend:    backend,
					controller: NewController(backend),
					settings:   Defaults(),
					directory:  t.TempDir(),
					releaseLock: func() {
						lockReleased.Store(true)
					},
					jobs:   make(chan uiResult, 1),
					closed: make(chan struct{}),
				}

				needRunning := dialogCase.name == "confirm_approve" || dialogCase.name == "help_info" || dialogCase.name == "error_dialog"
				if needRunning {
					if err := u.controller.Start(u.settings); err != nil {
						t.Fatalf("controller start: %v", err)
					}
					select {
					case <-readyCh:
					case <-time.After(3 * time.Second):
						t.Fatal("controller did not reach ready state")
					}
					deadline := time.Now().Add(2 * time.Second)
					for u.controller.Snapshot().Pending.ID == "" && time.Now().Before(deadline) {
						time.Sleep(10 * time.Millisecond)
					}
				}
				defer func() {
					<-u.controller.Stop()
				}()

				modalDismissed := make(chan struct{})
				u.cancelModal = func() {
					if cancelled.CompareAndSwap(false, true) {
						close(modalDismissed)
					}
				}
				u.modalRunner = func(kind, title, message string) (bool, string) {
					if !u.modal {
						t.Errorf("expected u.modal == true inside %s modal", kind)
					}
					if trigger == "signal" {
						u.requestQuit.Store(true)
						u.tick()
					} else {
						u.action(idExit)
					}
					select {
					case <-modalDismissed:
					case <-time.After(2 * time.Second):
						t.Errorf("termination (%s) did not dismiss open %s modal", trigger, kind)
					}
					// Even if a dialog callback returns an affirmative response during cancellation,
					// shutdown must ignore it and never mutate state.
					return true, "/tmp/should-not-import.json"
				}

				dialogCase.open(u)

				if !cancelled.Load() {
					t.Fatal("cancelModal was not invoked")
				}
				if u.modal {
					t.Fatal("u.modal remained true after dialog unwound")
				}
				if imported.Load() || forgot.Load() || approved.Load() {
					t.Fatalf("cancelled dialog mutated state: imported=%v forgot=%v approved=%v",
						imported.Load(), forgot.Load(), approved.Load())
				}

				deadline := time.Now().Add(3 * time.Second)
				for !u.destroyed && time.Now().Before(deadline) {
					u.tick()
					if !u.destroyed {
						time.Sleep(10 * time.Millisecond)
					}
				}
				if !u.destroyed {
					t.Fatalf("window did not complete shutdown after dismissing %s modal", dialogCase.name)
				}
				if !lockReleased.Load() {
					t.Fatal("instance lock was not released on modal shutdown")
				}
			})
		}
	}
}

func TestLinuxDesktopQuitDismissesOpenGTKDialogs(t *testing.T) {
	if !hasLinuxDisplay() {
		t.Skip("Linux GUI test requires DISPLAY or WAYLAND_DISPLAY")
	}
	setAllowModalsForTest(true)
	defer setAllowModalsForTest(false)

	uiDo := func(t *testing.T, fn func()) {
		t.Helper()
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

	waitForModal := func(t *testing.T) {
		t.Helper()
		deadline := time.Now().Add(5 * time.Second)
		for {
			var active bool
			uiDo(t, func() { active = hasActiveModalForTest() })
			if active {
				return
			}
			if time.Now().After(deadline) {
				t.Fatal("GTK modal dialog did not become active")
			}
			time.Sleep(15 * time.Millisecond)
		}
	}

	assertLockReleased := func(t *testing.T, dir string) {
		t.Helper()
		lockFile, already, err := acquireInstanceLock(dir)
		if err != nil || already || lockFile == nil {
			t.Fatalf("desktop.lock was not released: already=%v err=%v", already, err)
		}
		_ = syscall.Flock(int(lockFile.Fd()), syscall.LOCK_UN)
		_ = lockFile.Close()
	}

	t.Run("SIGTERMDismissesHelpDialogAndReleasesLock", func(t *testing.T) {
		configureTrayForTest(false, 0, "")
		defer configureTrayForTest(false, -1, "")

		started := make(chan struct{}, 1)
		hostStopped := make(chan struct{})
		finished := make(chan error, 1)

		backend := Backend{
			Run: func(ctx context.Context, _ Settings, _ <-chan Command, emit func(Event)) error {
				emit(Event{Kind: "ready", Message: "LAN control ready"})
				started <- struct{}{}
				<-ctx.Done()
				close(hostStopped)
				return nil
			},
			Devices: func() ([]AudioDevice, error) {
				return []AudioDevice{{ID: "speaker", Name: "PipeWire Output (test)", Default: true}}, nil
			},
			RemoteStatus: func() (string, error) { return "No remote configuration imported", nil },
		}

		dir := t.TempDir()
		settings := Defaults()
		settings.Notifications = false
		if err := SaveSettings(dir, settings); err != nil {
			t.Fatal(err)
		}

		linuxMainThread <- func() {
			finished <- runWindow(backend, dir, true, false)
		}

		select {
		case <-started:
		case err := <-finished:
			t.Fatalf("runWindow failed to start: %v", err)
		case <-time.After(10 * time.Second):
			t.Fatal("runWindow startup timed out")
		}

		modalReturned := make(chan struct{})
		uiTestQueue <- func() {
			triggerControlForTest(idCableHelp, 0)
			close(modalReturned)
		}
		wakeTestQueue()

		waitForModal(t)

		if err := syscall.Kill(os.Getpid(), syscall.SIGTERM); err != nil {
			t.Fatalf("sending SIGTERM: %v", err)
		}

		select {
		case <-modalReturned:
		case <-time.After(5 * time.Second):
			t.Fatal("SIGTERM did not dismiss open GTK help dialog")
		}
		select {
		case <-hostStopped:
		case <-time.After(5 * time.Second):
			t.Fatal("SIGTERM did not stop running host")
		}
		select {
		case err := <-finished:
			if err != nil {
				t.Fatalf("runWindow returned error: %v", err)
			}
		case <-time.After(10 * time.Second):
			t.Fatal("runWindow did not finish after SIGTERM dismissed dialog")
		}
		assertLockReleased(t, dir)
	})

	for _, tc := range []struct {
		name string
		open func()
	}{
		{
			name: "ConfirmDialog",
			open: func() { triggerControlForTest(idForget, 0) },
		},
		{
			name: "FileChooserNativeDialog",
			open: func() { triggerControlForTest(idImport, 0) },
		},
		{
			name: "ErrorDialog",
			open: func() {
				if activeWindow != nil {
					activeWindow.showErr(errors.New("simulated configuration failure"))
				}
			},
		},
	} {
		t.Run(tc.name, func(t *testing.T) {
			t.Setenv("GSETTINGS_BACKEND", "memory")
			var mutated atomic.Bool
			devicesReady := make(chan struct{}, 1)
			finished := make(chan error, 1)
			backend := Backend{
				Devices: func() ([]AudioDevice, error) {
					select {
					case devicesReady <- struct{}{}:
					default:
					}
					return []AudioDevice{{ID: "speaker", Name: "PipeWire Output (test)", Default: true}}, nil
				},
				RemoteStatus: func() (string, error) { return "No remote configuration imported", nil },
				ImportRemote: func(string) error {
					mutated.Store(true)
					return nil
				},
				ForgetRemote: func() error {
					mutated.Store(true)
					return nil
				},
			}

			dir := t.TempDir()
			settings := Defaults()
			settings.Notifications = false
			if err := SaveSettings(dir, settings); err != nil {
				t.Fatal(err)
			}

			linuxMainThread <- func() {
				finished <- runWindow(backend, dir, false, true)
			}
			exited := false
			defer func() {
				if !exited {
					uiTestQueue <- func() {
						if activeWindow != nil {
							activeWindow.requestQuit.Store(true)
							activeWindow.tick()
						}
					}
					wakeTestQueue()
					select {
					case <-finished:
					case <-time.After(5 * time.Second):
					}
				}
			}()

			select {
			case <-devicesReady:
			case err := <-finished:
				exited = true
				t.Fatalf("runWindow exited early: %v", err)
			case <-time.After(5 * time.Second):
				t.Fatal("runWindow did not reach initial device refresh")
			}

			// Wait until initial refresh job is processed on GTK main thread.
			deadline := time.Now().Add(5 * time.Second)
			for {
				var ready bool
				uiDo(t, func() { ready = activeWindow != nil && !activeWindow.busy })
				if ready {
					break
				}
				if time.Now().After(deadline) {
					t.Fatal("window did not finish initial refresh")
				}
				time.Sleep(15 * time.Millisecond)
			}

			modalReturned := make(chan struct{})
			uiTestQueue <- func() {
				tc.open()
				close(modalReturned)
			}
			wakeTestQueue()

			waitForModal(t)

			uiDo(t, func() {
				if activeWindow != nil {
					activeWindow.requestQuit.Store(true)
					activeWindow.tick()
				}
			})

			select {
			case <-modalReturned:
			case <-time.After(5 * time.Second):
				t.Fatalf("termination did not dismiss %s", tc.name)
			}
			select {
			case err := <-finished:
				exited = true
				if err != nil {
					t.Fatalf("runWindow returned error: %v", err)
				}
			case <-time.After(10 * time.Second):
				t.Fatalf("runWindow hung after dismissing %s", tc.name)
			}
			if mutated.Load() {
				t.Fatalf("dismissed %s unexpectedly mutated remote configuration", tc.name)
			}
			assertLockReleased(t, dir)
		})
	}
}

func startPrivateDBusDaemon(t *testing.T) string {
	t.Helper()
	dbusBin, err := exec.LookPath("dbus-daemon")
	if err != nil {
		t.Skip("dbus-daemon not installed; skipping live D-Bus StatusNotifierWatcher test")
	}
	cmd := exec.Command(dbusBin, "--session", "--nofork", "--print-address=1")
	stdout, err := cmd.StdoutPipe()
	if err != nil {
		t.Fatalf("dbus-daemon stdout pipe: %v", err)
	}
	if err := cmd.Start(); err != nil {
		t.Fatalf("starting dbus-daemon: %v", err)
	}
	t.Cleanup(func() {
		_ = cmd.Process.Kill()
		_ = cmd.Wait()
	})
	lineCh := make(chan string, 1)
	go func() {
		sc := bufio.NewScanner(stdout)
		if sc.Scan() {
			lineCh <- strings.TrimSpace(sc.Text())
		} else {
			lineCh <- ""
		}
	}()
	select {
	case addr := <-lineCh:
		if addr == "" {
			t.Fatal("dbus-daemon returned empty session address")
		}
		return addr
	case <-time.After(5 * time.Second):
		t.Fatal("timed out waiting for dbus-daemon address")
		return ""
	}
}

func startMockStatusNotifierWatcher(t *testing.T, dbusAddr string, initialHostRegistered bool) (setHostRegistered func(bool)) {
	t.Helper()
	pyBin, err := exec.LookPath("python3")
	if err != nil {
		t.Skip("python3 not installed; skipping mock StatusNotifierWatcher service")
	}
	script := `
import ctypes, os, sys

addr = sys.argv[1]
host_reg = [1 if sys.argv[2] == "1" else 0]

gio = ctypes.CDLL("libgio-2.0.so.0")
glib = ctypes.CDLL("libglib-2.0.so.0")

glib.g_variant_new_boolean.argtypes = [ctypes.c_int]
glib.g_variant_new_boolean.restype = ctypes.c_void_p
glib.g_main_context_default.argtypes = []
glib.g_main_context_default.restype = ctypes.c_void_p
glib.g_main_context_iteration.argtypes = [ctypes.c_void_p, ctypes.c_int]
glib.g_main_context_iteration.restype = ctypes.c_int

gio.g_dbus_connection_new_for_address_sync.argtypes = [ctypes.c_char_p, ctypes.c_int, ctypes.c_void_p, ctypes.c_void_p, ctypes.c_void_p]
gio.g_dbus_connection_new_for_address_sync.restype = ctypes.c_void_p
gio.g_dbus_node_info_new_for_xml.argtypes = [ctypes.c_char_p, ctypes.c_void_p]
gio.g_dbus_node_info_new_for_xml.restype = ctypes.c_void_p
gio.g_dbus_node_info_lookup_interface.argtypes = [ctypes.c_void_p, ctypes.c_char_p]
gio.g_dbus_node_info_lookup_interface.restype = ctypes.c_void_p
gio.g_dbus_connection_emit_signal.argtypes = [ctypes.c_void_p, ctypes.c_char_p, ctypes.c_char_p, ctypes.c_char_p, ctypes.c_char_p, ctypes.c_void_p, ctypes.c_void_p]
gio.g_dbus_connection_emit_signal.restype = ctypes.c_int
gio.g_dbus_connection_flush_sync.argtypes = [ctypes.c_void_p, ctypes.c_void_p, ctypes.c_void_p]
gio.g_dbus_connection_flush_sync.restype = ctypes.c_int

GET_PROP = ctypes.CFUNCTYPE(ctypes.c_void_p, ctypes.c_void_p, ctypes.c_char_p, ctypes.c_char_p, ctypes.c_char_p, ctypes.c_char_p, ctypes.c_void_p, ctypes.c_void_p)
NAME_CB = ctypes.CFUNCTYPE(None, ctypes.c_void_p, ctypes.c_char_p, ctypes.c_void_p)

class VTable(ctypes.Structure):
    _fields_ = [
        ("method_call", ctypes.c_void_p),
        ("get_property", GET_PROP),
        ("set_property", ctypes.c_void_p),
        ("padding", ctypes.c_void_p * 8),
    ]

acquired = [False]

@GET_PROP
def on_get_prop(conn, sender, path, iface, prop, err, udata):
    if prop == b"IsStatusNotifierHostRegistered":
        return glib.g_variant_new_boolean(host_reg[0])
    return None

@NAME_CB
def on_acq(conn, name, udata):
    acquired[0] = True

vt = VTable(None, on_get_prop, None)
xml = (
    b"<node><interface name='org.kde.StatusNotifierWatcher'>"
    b"<property name='IsStatusNotifierHostRegistered' type='b' access='read'/>"
    b"<signal name='StatusNotifierHostRegistered'/>"
    b"<signal name='StatusNotifierHostUnregistered'/>"
    b"</interface></node>"
)
node = gio.g_dbus_node_info_new_for_xml(xml, None)
iface = gio.g_dbus_node_info_lookup_interface(node, b"org.kde.StatusNotifierWatcher")
conn = gio.g_dbus_connection_new_for_address_sync(addr.encode(), 9, None, None, None)

gio.g_dbus_connection_register_object.argtypes = [ctypes.c_void_p, ctypes.c_char_p, ctypes.c_void_p, ctypes.POINTER(VTable), ctypes.c_void_p, ctypes.c_void_p, ctypes.c_void_p]
gio.g_dbus_connection_register_object.restype = ctypes.c_uint
gio.g_dbus_connection_register_object(conn, b"/StatusNotifierWatcher", iface, ctypes.byref(vt), None, None, None)

gio.g_bus_own_name_on_connection.argtypes = [ctypes.c_void_p, ctypes.c_char_p, ctypes.c_int, NAME_CB, ctypes.c_void_p, ctypes.c_void_p, ctypes.c_void_p]
gio.g_bus_own_name_on_connection.restype = ctypes.c_uint
gio.g_bus_own_name_on_connection(conn, b"org.kde.StatusNotifierWatcher", 0, on_acq, None, None, None)

ctx = glib.g_main_context_default()
while not acquired[0]:
    glib.g_main_context_iteration(ctx, 1)

os.set_blocking(sys.stdin.fileno(), False)
sys.stdout.write("READY\n")
sys.stdout.flush()

buf = b""
import select
while True:
    while glib.g_main_context_iteration(ctx, 0):
        pass
    r, _, _ = select.select([sys.stdin], [], [], 0.01)
    if r:
        chunk = os.read(sys.stdin.fileno(), 64)
        if not chunk:
            break
        buf += chunk
        while b"\n" in buf:
            line, buf = buf.split(b"\n", 1)
            cmd = line.strip()
            if cmd == b"0":
                host_reg[0] = 0
                gio.g_dbus_connection_emit_signal(conn, None, b"/StatusNotifierWatcher", b"org.kde.StatusNotifierWatcher", b"StatusNotifierHostUnregistered", None, None)
                gio.g_dbus_connection_flush_sync(conn, None, None)
                sys.stdout.write("ACK\n")
                sys.stdout.flush()
            elif cmd == b"1":
                host_reg[0] = 1
                gio.g_dbus_connection_emit_signal(conn, None, b"/StatusNotifierWatcher", b"org.kde.StatusNotifierWatcher", b"StatusNotifierHostRegistered", None, None)
                gio.g_dbus_connection_flush_sync(conn, None, None)
                sys.stdout.write("ACK\n")
                sys.stdout.flush()
`
	initArg := "0"
	if initialHostRegistered {
		initArg = "1"
	}
	cmd := exec.Command(pyBin, "-c", script, dbusAddr, initArg)
	stdin, err := cmd.StdinPipe()
	if err != nil {
		t.Fatalf("watcher stdin pipe: %v", err)
	}
	stdout, err := cmd.StdoutPipe()
	if err != nil {
		t.Fatalf("watcher stdout pipe: %v", err)
	}
	if err := cmd.Start(); err != nil {
		t.Fatalf("starting watcher: %v", err)
	}
	t.Cleanup(func() {
		_ = stdin.Close()
		_ = cmd.Process.Kill()
		_ = cmd.Wait()
	})

	sc := bufio.NewScanner(stdout)
	readyCh := make(chan bool, 1)
	ackCh := make(chan bool, 4)
	go func() {
		for sc.Scan() {
			txt := strings.TrimSpace(sc.Text())
			if txt == "READY" {
				readyCh <- true
			} else if txt == "ACK" {
				ackCh <- true
			}
		}
	}()
	select {
	case <-readyCh:
	case <-time.After(5 * time.Second):
		t.Fatal("timed out waiting for mock StatusNotifierWatcher READY")
	}

	return func(registered bool) {
		val := "0\n"
		if registered {
			val = "1\n"
		}
		if _, err := io.WriteString(stdin, val); err != nil {
			t.Fatalf("sending watcher update: %v", err)
		}
		select {
		case <-ackCh:
		case <-time.After(5 * time.Second):
			t.Fatal("timed out waiting for mock StatusNotifierWatcher ACK")
		}
	}
}

func TestLinuxDesktopTrayHostAvailabilityFallback(t *testing.T) {
	if !hasLinuxDisplay() {
		t.Skip("Linux GUI test requires DISPLAY or WAYLAND_DISPLAY")
	}
	defer configureTrayForTest(false, -1, "")

	uiDo := func(t *testing.T, fn func()) {
		t.Helper()
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

	newBackend := func(started chan<- struct{}) Backend {
		return Backend{
			Run: func(ctx context.Context, _ Settings, _ <-chan Command, emit func(Event)) error {
				emit(Event{Kind: "ready", Message: "LAN control ready"})
				started <- struct{}{}
				<-ctx.Done()
				return nil
			},
			Devices: func() ([]AudioDevice, error) {
				return []AudioDevice{{ID: "speaker", Name: "PipeWire Output (test)", Default: true}}, nil
			},
			RemoteStatus: func() (string, error) { return "No remote configuration imported", nil },
		}
	}

	t.Run("AllocatedIndicatorWithoutWatcherUsesMinimizedAndCleanExit", func(t *testing.T) {
		dbusAddr := startPrivateDBusDaemon(t)
		configureTrayForTest(true, -1, dbusAddr)
		defer configureTrayForTest(false, -1, "")

		started := make(chan struct{}, 1)
		finished := make(chan error, 1)
		dir := t.TempDir()
		settings := Defaults()
		settings.Notifications = false
		if err := SaveSettings(dir, settings); err != nil {
			t.Fatal(err)
		}

		linuxMainThread <- func() {
			finished <- runWindow(newBackend(started), dir, true, false)
		}
		select {
		case <-started:
		case err := <-finished:
			t.Fatalf("runWindow failed to start: %v", err)
		case <-time.After(10 * time.Second):
			t.Fatal("runWindow startup timed out")
		}

		var hasTray, visible bool
		uiDo(t, func() {
			hasTray = hasTrayForTest()
			visible = windowVisibleForTest()
		})
		if hasTray {
			t.Fatal("expected hasTray == false when StatusNotifierWatcher is absent")
		}
		if !visible {
			t.Fatal("window was hidden despite having no active tray host")
		}

		uiDo(t, func() { closeWindowForTest() })
		select {
		case err := <-finished:
			if err != nil {
				t.Fatalf("runWindow returned error on close fallback: %v", err)
			}
		case <-time.After(10 * time.Second):
			t.Fatal("closing window without tray host did not exit cleanly")
		}
	})

	t.Run("WatcherWithUnregisteredHostUsesMinimizedAndCleanExit", func(t *testing.T) {
		dbusAddr := startPrivateDBusDaemon(t)
		_ = startMockStatusNotifierWatcher(t, dbusAddr, false)
		configureTrayForTest(true, -1, dbusAddr)
		defer configureTrayForTest(false, -1, "")

		started := make(chan struct{}, 1)
		finished := make(chan error, 1)
		dir := t.TempDir()
		settings := Defaults()
		settings.Notifications = false
		if err := SaveSettings(dir, settings); err != nil {
			t.Fatal(err)
		}

		linuxMainThread <- func() {
			finished <- runWindow(newBackend(started), dir, true, false)
		}
		select {
		case <-started:
		case err := <-finished:
			t.Fatalf("runWindow failed to start: %v", err)
		case <-time.After(10 * time.Second):
			t.Fatal("runWindow startup timed out")
		}

		var hasTray, visible bool
		uiDo(t, func() {
			hasTray = hasTrayForTest()
			visible = windowVisibleForTest()
		})
		if hasTray {
			t.Fatal("expected hasTray == false when IsStatusNotifierHostRegistered is false")
		}
		if !visible {
			t.Fatal("window was hidden despite IsStatusNotifierHostRegistered being false")
		}

		uiDo(t, func() { closeWindowForTest() })
		select {
		case err := <-finished:
			if err != nil {
				t.Fatalf("runWindow returned error: %v", err)
			}
		case <-time.After(10 * time.Second):
			t.Fatal("closing window with unregistered tray host did not exit cleanly")
		}
	})

	t.Run("ActiveHostHidesToTrayAndSurfacesWhenHostDisappears", func(t *testing.T) {
		dbusAddr := startPrivateDBusDaemon(t)
		setHost := startMockStatusNotifierWatcher(t, dbusAddr, true)
		configureTrayForTest(true, -1, dbusAddr)
		defer configureTrayForTest(false, -1, "")

		started := make(chan struct{}, 1)
		finished := make(chan error, 1)
		dir := t.TempDir()
		settings := Defaults()
		settings.Notifications = false
		if err := SaveSettings(dir, settings); err != nil {
			t.Fatal(err)
		}

		linuxMainThread <- func() {
			finished <- runWindow(newBackend(started), dir, true, false)
		}
		select {
		case <-started:
		case err := <-finished:
			t.Fatalf("runWindow failed to start: %v", err)
		case <-time.After(10 * time.Second):
			t.Fatal("runWindow startup timed out")
		}

		var hasTray, visible bool
		uiDo(t, func() {
			hasTray = hasTrayForTest()
			visible = windowVisibleForTest()
		})
		if !hasTray {
			t.Fatal("expected hasTray == true when IsStatusNotifierHostRegistered is true")
		}
		if visible {
			t.Fatal("expected --background launch to hide window when tray host is active")
		}

		// Show window, then verify delete-event hides to tray without exiting.
		uiDo(t, func() { goMicDropShow() })
		uiDo(t, func() { visible = windowVisibleForTest() })
		if !visible {
			t.Fatal("expected goMicDropShow to reveal window")
		}
		uiDo(t, func() { closeWindowForTest() })
		uiDo(t, func() { visible = windowVisibleForTest() })
		if visible {
			t.Fatal("expected closing window with active tray host to hide window")
		}
		select {
		case err := <-finished:
			t.Fatalf("closing window with active tray host unexpectedly exited: %v", err)
		case <-time.After(100 * time.Millisecond):
		}

		// Unregister the StatusNotifierHost mid-session; MicDrop must detect loss and surface the hidden window.
		setHost(false)
		deadline := time.Now().Add(5 * time.Second)
		for {
			uiDo(t, func() {
				hasTray = hasTrayForTest()
				visible = windowVisibleForTest()
			})
			if !hasTray && visible {
				break
			}
			if time.Now().After(deadline) {
				t.Fatalf("window did not surface after tray host disappeared: hasTray=%v visible=%v", hasTray, visible)
			}
			time.Sleep(20 * time.Millisecond)
		}

		// Now that no tray host is registered, closing the window must exit cleanly.
		uiDo(t, func() { closeWindowForTest() })
		select {
		case err := <-finished:
			if err != nil {
				t.Fatalf("runWindow returned error: %v", err)
			}
		case <-time.After(10 * time.Second):
			t.Fatal("closing window after tray host disappeared did not exit cleanly")
		}
	})
}

func TestLinuxDesktopDialogRepeatedOpenCloseFinalizesObjects(t *testing.T) {
	if !hasLinuxDisplay() {
		t.Skip("Linux GUI test requires DISPLAY or WAYLAND_DISPLAY")
	}
	t.Setenv("GSETTINGS_BACKEND", "memory")
	setAllowModalsForTest(true)
	defer setAllowModalsForTest(false)

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

	devicesReady := make(chan struct{}, 1)
	finished := make(chan error, 1)
	backend := Backend{
		Devices: func() ([]AudioDevice, error) {
			select {
			case devicesReady <- struct{}{}:
			default:
			}
			return []AudioDevice{{ID: "speaker", Name: "PipeWire Output (test)", Default: true}}, nil
		},
		RemoteStatus: func() (string, error) { return "No remote configuration imported", nil },
	}

	dir := t.TempDir()
	settings := Defaults()
	settings.Notifications = false
	if err := SaveSettings(dir, settings); err != nil {
		t.Fatal(err)
	}

	linuxMainThread <- func() {
		finished <- runWindow(backend, dir, false, true)
	}
	defer func() {
		uiDo(func() { triggerControlForTest(idExit, 0) })
		select {
		case err := <-finished:
			if err != nil {
				t.Errorf("runWindow returned error: %v", err)
			}
		case <-time.After(10 * time.Second):
			t.Error("runWindow did not finish cleanup")
		}
	}()

	select {
	case <-devicesReady:
	case err := <-finished:
		t.Fatalf("runWindow exited early: %v", err)
	case <-time.After(5 * time.Second):
		t.Fatal("runWindow did not reach initial device refresh")
	}

	deadline := time.Now().Add(5 * time.Second)
	for {
		var ready bool
		uiDo(func() { ready = activeWindow != nil && !activeWindow.busy })
		if ready {
			break
		}
		if time.Now().After(deadline) {
			t.Fatal("window did not finish initial refresh")
		}
		time.Sleep(15 * time.Millisecond)
	}

	var baseline int
	uiDo(func() { baseline = liveModalObjectsForTest() })
	if baseline != 0 {
		t.Fatalf("expected 0 live modal GObjects before test, got %d", baseline)
	}

	runDialogCycle := func(label string, minExpectedWhileOpen int, openFn func()) {
		closed := make(chan struct{})
		uiTestQueue <- func() {
			openFn()
			close(closed)
		}
		wakeTestQueue()

		waitDeadline := time.Now().Add(5 * time.Second)
		var liveWhileOpen int
		for {
			var active bool
			uiDo(func() {
				active = hasActiveModalForTest()
				liveWhileOpen = liveModalObjectsForTest()
			})
			if active {
				break
			}
			if time.Now().After(waitDeadline) {
				t.Fatalf("%s modal did not become active", label)
			}
			time.Sleep(10 * time.Millisecond)
		}
		if liveWhileOpen < minExpectedWhileOpen {
			t.Fatalf("%s: expected at least %d tracked live GObject(s) while open, got %d",
				label, minExpectedWhileOpen, liveWhileOpen)
		}

		uiDo(func() { dismissModalsForTest() })
		select {
		case <-closed:
		case <-time.After(5 * time.Second):
			t.Fatalf("%s modal did not close after dismiss", label)
		}

		var retained int
		uiDo(func() { retained = liveModalObjectsForTest() })
		if retained != 0 {
			t.Fatalf("%s leaked %d modal GObject(s) after close", label, retained)
		}
	}

	// Regression check: 25 repeated Import dialog (GtkFileChooserNative + GtkFileFilter) cycles
	// must finalize both objects on every close and retain 0 GObjects.
	for i := 0; i < 25; i++ {
		runDialogCycle("ImportDialog", 2, func() { triggerControlForTest(idImport, 0) })
	}

	// Also verify repeated GtkMessageDialog cycles (help, confirm, error) finalize cleanly.
	for i := 0; i < 5; i++ {
		runDialogCycle("HelpDialog", 1, func() { triggerControlForTest(idCableHelp, 0) })
		runDialogCycle("ConfirmDialog", 1, func() { triggerControlForTest(idForget, 0) })
		runDialogCycle("ErrorDialog", 1, func() {
			if activeWindow != nil {
				activeWindow.showErr(errors.New("simulated failure"))
			}
		})
	}
}

func TestLinuxDesktopTrayCleanupDestroysMenuBeforeIndicator(t *testing.T) {
	if !hasLinuxDisplay() {
		t.Skip("Linux GUI test requires DISPLAY or WAYLAND_DISPLAY")
	}
	defer configureTrayForTest(false, -1, "")

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

	dbusAddr := startPrivateDBusDaemon(t)
	_ = startMockStatusNotifierWatcher(t, dbusAddr, true)
	configureTrayForTest(true, -1, dbusAddr)

	for cycle := 0; cycle < 5; cycle++ {
		started := make(chan struct{}, 1)
		finished := make(chan error, 1)
		backend := Backend{
			Run: func(ctx context.Context, _ Settings, _ <-chan Command, emit func(Event)) error {
				emit(Event{Kind: "ready", Message: "LAN control ready"})
				started <- struct{}{}
				<-ctx.Done()
				return nil
			},
			Devices: func() ([]AudioDevice, error) {
				return []AudioDevice{{ID: "speaker", Name: "PipeWire Output (test)", Default: true}}, nil
			},
			RemoteStatus: func() (string, error) { return "No remote configuration imported", nil },
		}

		dir := t.TempDir()
		settings := Defaults()
		settings.Notifications = false
		if err := SaveSettings(dir, settings); err != nil {
			t.Fatal(err)
		}

		linuxMainThread <- func() {
			finished <- runWindow(backend, dir, true, false)
		}
		select {
		case <-started:
		case err := <-finished:
			t.Fatalf("cycle %d: runWindow failed to start: %v", cycle, err)
		case <-time.After(10 * time.Second):
			t.Fatalf("cycle %d: runWindow startup timed out", cycle)
		}

		var liveDuring int
		uiDo(func() {
			liveDuring, _ = trayCleanupStatsForTest()
		})
		if liveDuring != 2 {
			t.Fatalf("cycle %d: expected 2 live tray GObjects (indicator + sunk GtkMenu) while running, got %d", cycle, liveDuring)
		}

		uiDo(func() { triggerControlForTest(idExit, 0) })
		select {
		case err := <-finished:
			if err != nil {
				t.Fatalf("cycle %d: runWindow returned error: %v", cycle, err)
			}
		case <-time.After(10 * time.Second):
			t.Fatalf("cycle %d: runWindow did not finish cleanup", cycle)
		}

		var liveAfter int
		var destroyedWhileAlive bool
		done := make(chan struct{})
		linuxMainThread <- func() {
			liveAfter, destroyedWhileAlive = trayCleanupStatsForTest()
			close(done)
		}
		<-done

		if !destroyedWhileAlive {
			t.Fatalf("cycle %d: tray GtkMenu finalized before gtk_widget_destroy ran", cycle)
		}
		if liveAfter != 0 {
			t.Fatalf("cycle %d: leaked %d tray GObject(s) after md_app_cleanup", cycle, liveAfter)
		}
	}
}
