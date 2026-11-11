package desktop

import (
	"strings"
	"testing"
	"time"

	"github.com/maskarauder/MicDrop/internal/phonecontrol"
)

func TestConnectionDetailsDoNotPresentOldMeasurementsAsLive(t *testing.T) {
	now := time.Now()
	rtt := 35.0
	device := DeviceConnection{State: "connected", UpdatedAt: now, MetricsAt: now, Settings: &phonecontrol.Snapshot{}, Metrics: ConnectionMetrics{RTTMS: &rtt}}
	if !phoneSettingsAvailable(device, now) || !strings.Contains(connectionMetricsLabel(device, now), "Network RTT 35 ms") {
		t.Fatal("fresh connected measurements were unavailable")
	}
	device.MetricsAt = now.Add(-11 * time.Second)
	if !phoneSettingsAvailable(device, now) || strings.Contains(connectionMetricsLabel(device, now), "35 ms") {
		t.Fatal("fresh settings made old audio statistics appear live")
	}
	device.State = "paused"
	if phoneSettingsAvailable(device, now) || !strings.Contains(connectionMetricsLabel(device, now), "last reported") {
		t.Fatal("paused state incorrectly implied live control or presence")
	}
	device.State = "connected"
	device.UpdatedAt = now.Add(-11 * time.Second)
	if phoneSettingsAvailable(device, now) {
		t.Fatal("stale phone allowed settings changes")
	}
}

func TestUnavailablePhoneSettingsExplainTheCause(t *testing.T) {
	const (
		offline = "Phone settings are available only while this phone is connected. Resume or reconnect it to make changes."
		older   = "This phone's MicDrop version can't share its settings with Windows. Update MicDrop on the phone, then connect again, to change its settings here."
		waiting = "Waiting for the phone to share its current settings…"
	)
	now := time.Now()
	settings, stale := &phonecontrol.Snapshot{}, now.Add(-11*time.Second)
	for _, tc := range []struct {
		name   string
		device DeviceConnection
		found  bool
		want   string
	}{
		{"editable", DeviceConnection{State: "connected", UpdatedAt: now, Settings: settings, SettingsSupported: true}, true, ""},
		// The host accepts a snapshot only from a phone that negotiated it.
		{"snapshot without the flag", DeviceConnection{State: "connected", UpdatedAt: now, Settings: settings}, true, ""},
		{"row removed", DeviceConnection{State: "connected", UpdatedAt: now, Settings: settings, SettingsSupported: true}, false, offline},
		{"paused", DeviceConnection{State: "paused", UpdatedAt: now, Settings: settings, SettingsSupported: true}, true, offline},
		{"interrupted", DeviceConnection{State: "interrupted", UpdatedAt: now, Settings: settings, SettingsSupported: true}, true, offline},
		{"reconnecting", DeviceConnection{State: "reconnecting", UpdatedAt: now, SettingsSupported: true}, true, offline},
		{"older phone offline", DeviceConnection{State: "disconnected"}, true, offline},
		{"older phone", DeviceConnection{State: "connected", UpdatedAt: now}, true, older},
		{"older phone, stale heartbeat", DeviceConnection{State: "connected", UpdatedAt: stale}, true, older},
		{"first snapshot pending", DeviceConnection{State: "connected", UpdatedAt: now, SettingsSupported: true}, true, waiting},
		{"no heartbeat yet", DeviceConnection{State: "connected", SettingsSupported: true}, true, waiting},
		{"stale snapshot", DeviceConnection{State: "connected", UpdatedAt: stale, Settings: settings, SettingsSupported: true}, true, waiting},
	} {
		got := phoneSettingsUnavailableMessage(tc.device, tc.found, now)
		if got != tc.want || (got == "") != (tc.found && phoneSettingsAvailable(tc.device, now)) || strings.Contains(got, "Android") {
			t.Fatalf("%s: %q", tc.name, got)
		}
	}
}
