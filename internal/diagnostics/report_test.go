package diagnostics

import (
	"math"
	"strings"
	"testing"
	"time"
)

func pointer[T any](v T) *T { return &v }

func outputFixture() *Output {
	return &Output{Backend: "webrtc_audiotrack", CapturedUptimeMS: 9000,
		Route: pointer("Bluetooth A2DP media"), TrackGeneration: 1, SampleRateHz: 48000,
		Channels: 2, BufferFrames: 960, CapacityFrames: 4800, PerformanceMode: "none",
		TimestampAgeMS: pointer(-20.0), EstimatedQueueMS: pointer(120.0)}
}

func reportFixture() *AndroidReport {
	return &AndroidReport{Sequence: 1, CapturedAt: time.Now(), UptimeMS: 10000,
		State: "Connected", MediaOutput: "running", Codec: "Opus", Path: "direct / udp",
		Metrics: map[string]*float64{}, Output: outputFixture(),
		Recovery: &Recovery{FastAccelerate: true, Phase: "settled", EpisodeMS: 8000,
			SettledAfterMS: pointer(int64(6000)), PeakBufferMS: pointer(800.0)}}
}

func TestRecoveryReportsPermitOnlyFixedRoutesAndBoundedCounts(t *testing.T) {
	r := reportFixture()
	r.LANRecovery = &LANRecovery{Phase: "recovering", Restarts: 2, SignalingRoute: "wifi"}
	if !r.Valid() {
		t.Fatal("fixed recovery policy rejected")
	}
	for _, change := range []func(*LANRecovery){
		func(l *LANRecovery) { l.SignalingRoute = "private-network-name" },
		func(l *LANRecovery) { l.Phase = "arbitrary error text" },
		func(l *LANRecovery) { l.Restarts = 1_000_001 },
	} {
		r.LANRecovery = &LANRecovery{Phase: "recovering", Restarts: 2, SignalingRoute: "wifi"}
		change(r.LANRecovery)
		if r.Valid() {
			t.Fatal("unbounded/private recovery report accepted")
		}
	}
}
func TestMicrophoneProcessingReportsRequireTheirSupportedDirectionAndRoute(t *testing.T) {
	r := reportFixture()
	r.Direction = "duplex"
	r.Microphone = &Microphone{State: "running", Route: "built-in microphone", SampleRate: 48000, Channels: 1,
		RequestedRoute: "built-in microphone", RouteVerified: pointer(true), Processing: &MicrophoneProcessing{EchoCancellation: true, NoiseReduction: true}}
	if !r.Valid() {
		t.Fatal("duplex processing rejected")
	}
	r.Direction = ""
	if r.Valid() {
		t.Fatal("microphone-only echo reference fabricated")
	}
	r.Microphone.Processing.EchoCancellation = false
	if !r.Valid() {
		t.Fatal("microphone-only noise processing rejected")
	}
	r.Microphone.RequestedRoute = "Bluetooth SCO microphone"
	r.Microphone.Route = "Bluetooth SCO microphone"
	if r.Valid() {
		t.Fatal("Bluetooth software processing fabricated")
	}
}

func TestOutputExtensionAcceptsUnknownsAndLegacyReports(t *testing.T) {
	r := reportFixture()
	if !r.Valid() {
		t.Fatal("valid timing including a future committed timestamp rejected")
	}
	r.LocalOutput = outputFixture()
	r.LocalOutput.Backend = "local_audiotrack"
	r.LocalOutput.Route = nil
	r.LocalOutput.TimestampAgeMS = nil
	r.LocalOutput.EstimatedQueueMS = nil
	if !r.Valid() {
		t.Fatal("optional baseline / missing timing rejected")
	}
	r.Output, r.Recovery, r.LocalOutput = nil, nil, nil
	if !r.Valid() {
		t.Fatal("legacy report rejected")
	}
}

func TestOutputRejectsIdentifiersBadTimingAndInconsistentRecovery(t *testing.T) {
	for _, change := range []func(*AndroidReport){
		func(r *AndroidReport) { r.Output.Route = pointer("secret-headset-name") },
		func(r *AndroidReport) { r.Output.Backend = "secret-address" },
		func(r *AndroidReport) { r.Output.CapturedUptimeMS = 10001 },
		func(r *AndroidReport) { r.Output.SampleRateHz = 0 },
		func(r *AndroidReport) { r.Output.BufferFrames = 4801 },
		func(r *AndroidReport) { r.Output.RouteChanges = -1 },
		func(r *AndroidReport) { r.Output.EstimatedQueueMS = pointer(math.NaN()) },
		func(r *AndroidReport) { r.Output.EstimatedQueueMS = pointer(math.Inf(1)) },
		func(r *AndroidReport) { r.Output.EstimatedQueueMS = pointer(-1.0) },
		func(r *AndroidReport) { r.Output.TimestampAgeMS = pointer(1001.0) },
		func(r *AndroidReport) { r.Output.TimestampAgeMS = nil },
		func(r *AndroidReport) { r.Recovery.SettledAfterMS = nil },
		func(r *AndroidReport) { r.Recovery.SettledAfterMS = pointer(int64(8001)) },
		func(r *AndroidReport) { r.Recovery.Phase = "settling" },
		func(r *AndroidReport) { r.LocalOutput = outputFixture() },
	} {
		r := reportFixture()
		change(r)
		if r.Valid() {
			t.Fatal("invalid output or recovery report accepted")
		}
	}
}

func TestMicrophoneReportBoundsAndDirectionSpecificMetrics(t *testing.T) {
	fixture := func() *AndroidReport {
		r := reportFixture()
		r.Output, r.Recovery = nil, nil
		r.MediaOutput = "waiting"
		r.Microphone = &Microphone{State: "running", Route: "built-in microphone", SampleRate: 48000, Channels: 1}
		r.Metrics = map[string]*float64{"sent_bytes_total": pointer(8000.0), "sent_packets": pointer(200.0), "sent_payload_kbps": pointer(64.0)}
		return r
	}
	r := fixture()
	if !r.Valid() {
		t.Fatal("valid microphone report rejected")
	}
	r.Microphone = &Microphone{State: "muted", Route: "unavailable"}
	if !r.Valid() {
		t.Fatal("stopped capture while muted rejected")
	}
	r.Microphone = &Microphone{State: "waiting", Route: "unavailable"}
	if !r.Valid() {
		t.Fatal("unavailable input observation rejected")
	}
	for _, change := range []func(*AndroidReport){
		func(r *AndroidReport) { r.Microphone = nil },
		func(r *AndroidReport) { r.Microphone.Route = "secret-device-name" },
		func(r *AndroidReport) { r.Microphone.Route = "unavailable" },
		func(r *AndroidReport) { r.Microphone.State = "secret-error" },
		func(r *AndroidReport) { r.Microphone.SampleRate = 0 },
		func(r *AndroidReport) { r.Microphone.SampleRate = 384001 },
		func(r *AndroidReport) { r.Microphone.Channels = 2 },
		func(r *AndroidReport) { r.Metrics["sent_payload_kbps"] = pointer(-1.0) },
		func(r *AndroidReport) { r.Metrics["sent_bytes_total"] = pointer(math.NaN()) },
		func(r *AndroidReport) { r.Metrics["raw_audio"] = pointer(1.0) },
	} {
		r := fixture()
		change(r)
		if r.Valid() {
			t.Fatal("invalid microphone report accepted")
		}
	}
}

func TestSelectedMicrophoneReportsRequireConsistentVerification(t *testing.T) {
	for _, route := range []string{"built-in microphone", "wired headset microphone", "USB microphone", "Bluetooth SCO microphone", "Bluetooth LE microphone"} {
		r := reportFixture()
		r.Direction = "duplex"
		r.Microphone = &Microphone{State: "running", Route: route, SampleRate: 48000, Channels: 1,
			RequestedRoute: route, RouteVerified: pointer(true)}
		if !r.Valid() {
			t.Fatalf("selected route %q rejected", route)
		}
		for _, change := range []func(*Microphone){
			func(m *Microphone) { m.RequestedRoute = "secret-device-name" },
			func(m *Microphone) { m.RequestedRoute = "" },
			func(m *Microphone) { m.Route = "unavailable" },
			func(m *Microphone) { m.RouteVerified = nil },
			func(m *Microphone) { m.RouteVerified = pointer(false) },
		} {
			original := *r.Microphone
			changed := original
			change(&changed)
			r.Microphone = &changed
			if r.Valid() {
				t.Fatalf("inconsistent selection accepted for %q", route)
			}
			r.Microphone = &original
		}
		r.Microphone.State, r.Microphone.Route, r.Microphone.RouteVerified = "muted", "unavailable", pointer(false)
		if !r.Valid() {
			t.Fatal("muted selected input rejected")
		}
		r.Microphone.State, r.Microphone.Route = "waiting", "built-in microphone"
		if !r.Valid() {
			t.Fatal("gated unverified input observation rejected")
		}
	}
}

func TestMutedCaptureReportsStillRequireVerifiedRouteAndFormat(t *testing.T) {
	for _, direction := range []string{"", "duplex"} {
		for _, route := range strings.Split(microphoneRoutes, "|") {
			r := reportFixture()
			r.Direction = direction
			r.Microphone = &Microphone{State: "muted", Route: route, SampleRate: 48000, Channels: 1,
				RequestedRoute: route, RouteVerified: pointer(true)}
			if !r.Valid() {
				t.Fatalf("verified muted capture rejected: direction=%q route=%q", direction, route)
			}
			for _, change := range []func(*Microphone){
				func(m *Microphone) { m.Route = "unavailable" },
				func(m *Microphone) { m.RequestedRoute = "unavailable" },
				func(m *Microphone) { m.SampleRate = 0 },
				func(m *Microphone) { m.Channels = 0 },
				func(m *Microphone) { m.Channels = 2 },
				func(m *Microphone) { m.RouteVerified = nil },
			} {
				original := *r.Microphone
				change(r.Microphone)
				if r.Valid() {
					t.Fatalf("inconsistent muted capture accepted: %+v", r.Microphone)
				}
				*r.Microphone = original
			}
		}
	}
}
