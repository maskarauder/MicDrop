package diagnostics

import "time"

const MaxTerminalBody = 8 * 1024

// Nullable observations distinguish a failed/unavailable Android query from a
// negative result. Default network facts do not identify the media's ICE route.
type Runtime struct {
	ScreenOn                  *bool  `json:"screen_on"`
	BatterySaver              *bool  `json:"battery_saver"`
	DeviceIdle                *bool  `json:"device_idle"`
	BatteryExempt             *bool  `json:"battery_optimization_exempt"`
	MicrophonePermission      *bool  `json:"microphone_permission"`
	WakeLockHeld              *bool  `json:"wake_lock_held"`
	DefaultNetwork            string `json:"default_network"`
	NetworkValidated          *bool  `json:"network_validated"`
	NetworkMetered            *bool  `json:"network_metered"`
	NetworkBlocked            *bool  `json:"network_blocked"`
	NetworkChanges            int64  `json:"network_changes"`
	LightIdle                 *bool  `json:"light_idle"`
	LowPowerStandby           *bool  `json:"low_power_standby_enabled"`
	LowPowerStandbyExempt     *bool  `json:"low_power_standby_exempt"`
	NetworkObserverRegistered *bool  `json:"network_observer_registered"`
	ForegroundService         string `json:"foreground_service"`
}

type Connection struct {
	Peer    string   `json:"peer"`
	ICE     string   `json:"ice"`
	Host    string   `json:"host"`
	Runtime *Runtime `json:"runtime"`
}

type ConnectionEvent struct {
	UptimeMS int64  `json:"uptime_ms"`
	Kind     string `json:"kind"`
	Value    string `json:"value"`
}

type ReceiverEnd struct {
	Version         int               `json:"version"`
	CapturedAt      time.Time         `json:"captured_at"`
	UptimeMS        int64             `json:"uptime_ms"`
	Code            string            `json:"code"`
	Stage           string            `json:"stage"`
	FailureUptimeMS *int64            `json:"failure_uptime_ms"`
	Connection      *Connection       `json:"connection"`
	Events          []ConnectionEvent `json:"events"`
	OmittedEvents   int64             `json:"omitted_events"`
	HTTPStatus      *int              `json:"http_status"`
	OutputControl   *OutputControl    `json:"output_control,omitempty"`
	ICEGathering    *ICEGathering     `json:"ice_gathering,omitempty"`
}

const peerStates = "connecting|new|connected|disconnected|failed|closed"
const iceStates = "new|checking|connected|completed|disconnected|failed|closed"
const hostStates = peerStates + "|unavailable"
const networkStates = "none|unknown|wifi|cellular|ethernet|vpn|other"
const foregroundTypes = "none|unknown|microphone|media_playback|microphone_and_playback|other"
const failureCodes = "none|peer_failed|media_recovery_timeout|status_recovery_timeout|host_audio_stopped|microphone_init|microphone_start|microphone_runtime|output_init|output_start|output_runtime|input_route_changed|input_unverified|le_stereo_unavailable|host_microphone_gate|mode_not_confirmed|http_rejected|tls_failure|permission_denied|network_io|stage_timeout|native_load|session_exception"

func (c *Connection) Valid() bool {
	if c == nil {
		return true // Optional on older heartbeat reports, required at terminal.
	}
	if !member(c.Peer, peerStates) || !member(c.ICE, iceStates) || !member(c.Host, hostStates) {
		return false
	}
	r := c.Runtime
	return r == nil || (member(r.DefaultNetwork, networkStates) && (r.ForegroundService == "" || member(r.ForegroundService, foregroundTypes)) &&
		r.NetworkChanges >= 0 && r.NetworkChanges <= 1<<53-1)
}

func (e ConnectionEvent) valid(uptime int64) bool {
	if e.UptimeMS < 0 || e.UptimeMS > uptime {
		return false
	}
	switch e.Kind {
	case "peer":
		return member(e.Value, peerStates)
	case "ice":
		return member(e.Value, iceStates)
	case "host":
		return member(e.Value, hostStates)
	case "network":
		return member(e.Value, networkStates+"|available|lost")
	case "foreground_service":
		return member(e.Value, foregroundTypes)
	case "network_blocked", "screen", "idle", "battery_saver", "battery_exempt", "microphone_permission", "wake_lock", "network_validated", "network_metered", "light_idle", "low_power_standby", "low_power_exempt":
		return member(e.Value, "true|false|unknown")
	}
	return false
}

func (e *ReceiverEnd) Valid(reason string) bool {
	if e == nil {
		return true
	}
	if e.Version != 1 || e.CapturedAt.IsZero() || e.UptimeMS < 0 || !member(e.Code, failureCodes) ||
		!member(e.Stage, "waiting|pairing|audio|codec|offer|answer|routes|submitting|playback|input_route|microphone") ||
		e.Connection == nil || !e.Connection.Valid() || len(e.Events) > 24 || e.OmittedEvents < 0 || e.OmittedEvents > 1<<53-1 {
		return false
	}
	if !e.OutputControl.valid() || !e.ICEGathering.valid() {
		return false
	}
	failed := reason == "connection_failed"
	if failed != (e.Code != "none") || failed != (e.FailureUptimeMS != nil) ||
		(e.HTTPStatus != nil && (!failed || *e.HTTPStatus < 100 || *e.HTTPStatus > 599)) ||
		(e.FailureUptimeMS != nil && (*e.FailureUptimeMS < 0 || *e.FailureUptimeMS > e.UptimeMS)) {
		return false
	}
	var last int64
	for _, event := range e.Events {
		if !event.valid(e.UptimeMS) || event.UptimeMS < last {
			return false
		}
		last = event.UptimeMS
	}
	return true
}
