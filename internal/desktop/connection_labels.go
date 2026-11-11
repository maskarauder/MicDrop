package desktop

import (
	"encoding/json"
	"fmt"
	"math"
	"strings"
	"time"

	"github.com/maskarauder/MicDrop/internal/phonecontrol"
)

func connectionStateLabel(state string) string {
	switch state {
	case "connected":
		return "Connected"
	case "paused":
		return "Paused (last reported)"
	case "interrupted":
		return "Interrupted (last reported)"
	case "connecting", "new":
		return "Connecting"
	case "reconnecting", "checking", "disconnected", "failed":
		if state != "disconnected" {
			return "Reconnecting"
		}
	}
	return "Offline"
}

func freshPhoneTime(value, now time.Time) bool {
	return !value.IsZero() && now.Sub(value) >= 0 && now.Sub(value) <= 10*time.Second
}

func phoneSettingsAvailable(device DeviceConnection, now time.Time) bool {
	return device.State == "connected" && device.Settings != nil && freshPhoneTime(device.UpdatedAt, now)
}

// phoneSettingsUnavailableMessage is "" while settings can be edited. Only the
// host's negotiation flag separates an older phone from a current one that has
// not yet sent its first snapshot.
func phoneSettingsUnavailableMessage(device DeviceConnection, found bool, now time.Time) string {
	switch {
	case found && phoneSettingsAvailable(device, now):
		return ""
	case !found || device.State != "connected":
		return "Phone settings are available only while this phone is connected. Resume or reconnect it to make changes."
	case !device.SettingsSupported:
		return "This phone's MicDrop version can't share its settings with Windows. Update MicDrop on the phone, then connect again, to change its settings here."
	}
	return "Waiting for the phone to share its current settings…"
}

func connectionMetricsLabel(device DeviceConnection, now time.Time) string {
	if device.State != "connected" {
		return connectionStateLabel(device.State) + " · Live statistics unavailable.\r\nEnd-to-end audio and microphone delay are not measured."
	}
	if !freshPhoneTime(device.MetricsAt, now) {
		return "Waiting for current phone statistics.\r\nEnd-to-end audio and microphone delay are not measured."
	}
	number := func(value *float64) string {
		if value == nil || math.IsNaN(*value) || math.IsInf(*value, 0) || *value < 0 {
			return "—"
		}
		return fmt.Sprintf("%.0f ms", *value)
	}
	return "Network RTT " + number(device.Metrics.RTTMS) + " · RTP jitter " + number(device.Metrics.JitterMS) +
		"\r\nPlayback buffer " + number(device.Metrics.PlaybackBufferMS) + " · Output queue ~" + number(device.Metrics.OutputQueueMS)
}

func phoneFieldValue(field phonecontrol.Field) string {
	switch field.Kind {
	case "bool":
		var value bool
		if json.Unmarshal(field.Value, &value) == nil && value {
			return "On"
		}
		return "Off"
	case "choice":
		var value string
		_ = json.Unmarshal(field.Value, &value)
		for _, choice := range field.Choices {
			if value == choice.Value {
				return choice.Label
			}
		}
		return "Unavailable"
	default:
		return strings.TrimSpace(string(field.Value))
	}
}
