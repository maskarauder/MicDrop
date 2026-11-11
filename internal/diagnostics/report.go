// Package diagnostics stores bounded, address-free session statistics, never audio.
package diagnostics

import (
	"math"
	"strings"
	"time"
	"unicode"
	"unicode/utf8"

	"github.com/maskarauder/MicDrop/internal/rtc"
)

const MaxReportBody = 16 * 1024

type Environment struct {
	AppVersion     string   `json:"app_version"`
	Revision       string   `json:"revision"`
	Manufacturer   string   `json:"manufacturer"`
	Model          string   `json:"model"`
	AndroidRelease string   `json:"android_release"`
	API            int      `json:"api"`
	ExpectedRoutes []string `json:"expected_routes"`
	AudioMode      string   `json:"audio_mode"`
	ScreenOn       bool     `json:"screen_on"`
	BatterySaver   bool     `json:"battery_saver"`
}

type AndroidReport struct {
	Sequence        uint64              `json:"sequence"`
	CapturedAt      time.Time           `json:"captured_at"`
	UptimeMS        int64               `json:"uptime_ms"`
	Environment     *Environment        `json:"environment"`
	State           string              `json:"state"`
	MediaOutput     string              `json:"media_output"`
	Codec           string              `json:"codec"`
	Path            string              `json:"path"`
	Metrics         map[string]*float64 `json:"metrics"`
	Output          *Output             `json:"output,omitempty"`
	Recovery        *Recovery           `json:"recovery,omitempty"`
	LocalOutput     *Output             `json:"local_output_baseline,omitempty"`
	Microphone      *Microphone         `json:"microphone,omitempty"`
	Direction       string              `json:"audio_direction,omitempty"`
	Connection      *Connection         `json:"connection,omitempty"`
	LANRecovery     *LANRecovery        `json:"lan_recovery,omitempty"`
	OutputControl   *OutputControl      `json:"output_control,omitempty"`
	ICEGathering    *ICEGathering       `json:"ice_gathering,omitempty"`
	MediaTransport  *rtc.MediaTransport `json:"media_transport,omitempty"`
	RouteSelection  *rtc.RouteSelection `json:"route_selection,omitempty"`
	TLSVerification *TLSVerification    `json:"tls_certificate_verification,omitempty"`
}

type LANRecovery struct {
	Phase          string `json:"phase"`
	Restarts       uint64 `json:"restarts"`
	SignalingRoute string `json:"signaling_route"`
}
type MicrophoneProcessing struct {
	EchoCancellation bool `json:"echo_cancellation_requested"`
	NoiseReduction   bool `json:"noise_reduction_requested"`
}

type Microphone struct {
	State          string                `json:"state"`
	Route          string                `json:"route"`
	SampleRate     int                   `json:"sample_rate_hz"`
	Channels       int                   `json:"channels"`
	RequestedRoute string                `json:"requested_route,omitempty"`
	RouteVerified  *bool                 `json:"route_verified,omitempty"`
	Processing     *MicrophoneProcessing `json:"processing,omitempty"`
}

type Output struct {
	Backend          string   `json:"backend"`
	CapturedUptimeMS int64    `json:"captured_uptime_ms"`
	Route            *string  `json:"route"`
	TrackGeneration  int      `json:"track_generation"`
	RouteChanges     int      `json:"route_changes"`
	SampleRateHz     int      `json:"sample_rate_hz"`
	Channels         int      `json:"channels"`
	BufferFrames     int      `json:"buffer_frames"`
	CapacityFrames   int      `json:"capacity_frames"`
	Underruns        int      `json:"underruns"`
	PerformanceMode  string   `json:"performance_mode"`
	TimestampAgeMS   *float64 `json:"timestamp_age_ms"`
	EstimatedQueueMS *float64 `json:"estimated_queue_ms"`
}

type Recovery struct {
	FastAccelerate bool     `json:"fast_accelerate"`
	Phase          string   `json:"phase"`
	EpisodeMS      int64    `json:"episode_ms"`
	SettledAfterMS *int64   `json:"settled_after_ms"`
	PeakBufferMS   *float64 `json:"peak_buffer_ms"`
}

const routes = "phone speaker|earpiece|wired headphones|USB audio|Bluetooth A2DP media|Bluetooth SCO voice|Bluetooth LE audio|hearing aid|HDMI|line output|other"
const microphoneRoutes = "built-in microphone|wired headset microphone|USB microphone|Bluetooth SCO microphone|Bluetooth LE microphone"

func bounded(value *float64, low, high float64) bool {
	return value == nil || (!math.IsNaN(*value) && !math.IsInf(*value, 0) && *value >= low && *value <= high)
}

func (o *Output) valid(backend string, uptime int64) bool {
	return o == nil || (o.Backend == backend && o.CapturedUptimeMS >= 0 && o.CapturedUptimeMS <= uptime &&
		(o.Route == nil || member(*o.Route, routes)) && o.TrackGeneration >= 1 && o.TrackGeneration <= 1000000 &&
		o.RouteChanges >= 0 && o.RouteChanges <= 1000000 && o.SampleRateHz >= 8000 && o.SampleRateHz <= 384000 &&
		o.Channels >= 1 && o.Channels <= 32 && o.BufferFrames >= 0 && o.CapacityFrames >= o.BufferFrames &&
		o.CapacityFrames <= 384000*60 && o.Underruns >= 0 && o.Underruns <= 1<<31-1 &&
		member(o.PerformanceMode, "none|low latency|power saving") && bounded(o.TimestampAgeMS, -1000, 1000) &&
		bounded(o.EstimatedQueueMS, 0, 60000) && (o.EstimatedQueueMS == nil || o.TimestampAgeMS != nil))
}

func member(value, choices string) bool {
	for _, choice := range strings.Split(choices, "|") {
		if value == choice {
			return true
		}
	}
	return false
}

// Accept only the explicit diagnostic schema. Arbitrary text, addresses, SDP,
// tokens, candidate IDs and filenames have no wire fields or logging path.
func (r *AndroidReport) Valid() bool {
	if r == nil || r.Sequence == 0 || r.Sequence > 1<<53-1 || r.CapturedAt.IsZero() || r.UptimeMS < 0 ||
		!member(r.State, "Connecting|New|Connected|Disconnected|Failed|Closed") ||
		!member(r.MediaOutput, "running|waiting") || !member(r.Codec, "Opus|unavailable") ||
		(r.Direction != "" && r.Direction != "duplex") || (r.Direction == "duplex" && r.Microphone == nil) {
		return false
	}
	if l := r.LANRecovery; l != nil {
		if !member(l.Phase, "settled|recovering") || l.Restarts > 1_000_000 ||
			!member(l.SignalingRoute, "default|wifi|ethernet|vpn|unavailable") {
			return false
		}
	}
	parts := strings.Split(r.Path, " / ")
	if len(parts) > 2 || !member(parts[0], "direct|relay|unavailable") || (len(parts) == 2 && !member(parts[1], "udp|tcp")) {
		return false
	}
	if e := r.Environment; e != nil {
		for _, value := range []string{e.AppVersion, e.Revision, e.Manufacturer, e.Model, e.AndroidRelease} {
			if !utf8.ValidString(value) || utf8.RuneCountInString(value) > 80 || strings.ContainsFunc(value, unicode.IsControl) {
				return false
			}
		}
		if e.API < 31 || e.API > 1000 || len(e.ExpectedRoutes) > 16 || !member(e.AudioMode, "normal|communication|call|ringtone|other") {
			return false
		}
		for _, route := range e.ExpectedRoutes {
			if !member(route, routes) {
				return false
			}
		}
	}
	if !r.Connection.Valid() || !r.Output.valid("webrtc_audiotrack", r.UptimeMS) || !r.LocalOutput.valid("local_audiotrack", r.UptimeMS) {
		return false
	}
	if !r.OutputControl.valid() || !r.ICEGathering.valid() || !r.MediaTransport.Valid() || !r.RouteSelection.Valid() || !r.TLSVerification.valid() {
		return false
	}
	if m := r.Microphone; m != nil {
		if p := m.Processing; p != nil {
			if (p.EchoCancellation && r.Direction != "duplex") ||
				((p.EchoCancellation || p.NoiseReduction) && strings.HasPrefix(m.RequestedRoute, "Bluetooth")) {
				return false
			}
		}
		if !member(m.State, "running|muted|waiting") || !member(m.Route, microphoneRoutes+"|unavailable") ||
			m.SampleRate < 0 || m.SampleRate > 384000 || m.Channels < 0 || m.Channels > 2 ||
			(m.State == "running" && (m.Route == "unavailable" || m.SampleRate < 8000 || m.Channels != 1)) {
			return false
		}
		if m.RequestedRoute != "" || m.RouteVerified != nil {
			// Muted describes transmission, not whether verified capture is retained.
			if !member(m.RequestedRoute, microphoneRoutes) || m.RouteVerified == nil ||
				(*m.RouteVerified && (m.Route != m.RequestedRoute || m.SampleRate < 8000 || m.Channels != 1)) ||
				(m.State == "running" && !*m.RouteVerified) {
				return false
			}
		} else if !member(m.Route, "built-in microphone|unavailable") {
			return false // Preserve old built-in reports; new inputs must carry selection verification.
		}
	}
	if recovery := r.Recovery; recovery != nil {
		if !member(recovery.Phase, "waiting|settling|settled") || recovery.EpisodeMS < 0 || recovery.EpisodeMS > r.UptimeMS ||
			!bounded(recovery.PeakBufferMS, 0, 60000) ||
			(recovery.SettledAfterMS != nil && (*recovery.SettledAfterMS < 0 || *recovery.SettledAfterMS > recovery.EpisodeMS)) ||
			((recovery.Phase == "settled") != (recovery.SettledAfterMS != nil)) {
			return false
		}
	}
	if r.Metrics == nil {
		return false
	}
	for key, value := range r.Metrics {
		if !member(key, "window_seconds|buffer_ms|buffer_target_ms|buffer_minimum_ms|jitter_ms|bytes_total|payload_kbps|received_packets|lost_packets|discarded_packets|concealed_samples|concealed_percent|inserted_samples|removed_samples|rtt_ms") &&
			!(r.Microphone != nil && member(key, "sent_bytes_total|sent_packets|sent_payload_kbps")) {
			return false
		}
		if value != nil && (math.IsNaN(*value) || math.IsInf(*value, 0) || math.Abs(*value) > 1e18 || (*value < 0 && key != "lost_packets")) {
			return false
		}
	}
	return true
}
