package session

import (
	"crypto/tls"
	"encoding/json"
	"net/http/httptest"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"

	"github.com/maskarauder/MicDrop/internal/diagnostics"
	"github.com/maskarauder/MicDrop/internal/rtc"
)

const androidReport = `{"version":1,"android":{"sequence":1,"captured_at":"2026-09-28T21:00:00Z","uptime_ms":10000,"environment":{"app_version":"0.1.0-dev","revision":"local","manufacturer":"Test","model":"Phone","android_release":"16","api":36,"expected_routes":["Bluetooth A2DP media"],"audio_mode":"normal","screen_on":true,"battery_saver":false},"state":"Connected","media_output":"running","codec":"Opus","path":"direct / udp","metrics":{"window_seconds":2,"buffer_ms":40,"rtt_ms":8,"lost_packets":-1,"discarded_packets":null}}}`

const outputExtension = `"output":{"backend":"webrtc_audiotrack","captured_uptime_ms":9990,"route":"Bluetooth A2DP media","track_generation":1,"route_changes":0,"sample_rate_hz":48000,"channels":2,"buffer_frames":960,"capacity_frames":4800,"underruns":0,"performance_mode":"none","timestamp_age_ms":-20,"estimated_queue_ms":120},"recovery":{"fast_accelerate":true,"phase":"settling","episode_ms":2000,"settled_after_ms":null,"peak_buffer_ms":800},"local_output_baseline":null,`

func TestRetainedMutedCaptureStatusAcceptsICEWithoutOpeningMicrophone(t *testing.T) {
	for _, duplex := range []bool{false, true} {
		for _, continuous := range []bool{false, true} {
			p := &continuousPeer{enabled: continuous}
			p.local = trickleDescription
			p.status = rtc.Status{State: "connected", MicrophoneMuted: true}
			path := filepath.Join(t.TempDir(), "muted.jsonl")
			source := diagnostics.PhoneMicrophone
			if duplex {
				source = diagnostics.DuplexCapture
			}
			l, _, err := diagnostics.Create(path, source, time.Now())
			if err != nil {
				t.Fatal(err)
			}
			t.Cleanup(func() { l.Close("test") })
			s := New(p, strings.Repeat("a", 43), time.Now(), WithDiagnostics(l))
			s.version, s.microphone, s.duplex = 3, true, duplex
			offer := `{"version":3,"microphone_return_version":1}`
			if duplex {
				offer = duplexOffer
			}
			r := httptest.NewRequest("POST", "https://paired.test/offer", strings.NewReader(offer))
			r.Header.Set("Authorization", "Bearer "+s.invitation)
			r.Header.Set("X-MicDrop-Trickle-ICE", "1")
			r.Header.Set(rtc.ContinuousHeader, "1")
			r.TLS = &tls.ConnectionState{}
			w := httptest.NewRecorder()
			s.ServeHTTP(w, r)
			if w.Code != 200 {
				t.Fatal("offer", w.Code, w.Body.String())
			}
			answer, _ := json.Marshal(map[string]any{"version": 3, "sdp": phoneDescription})
			if call(s, "/answer", s.session, string(answer)).Code != 200 {
				t.Fatal("answer")
			}
			var report struct {
				Android *diagnostics.AndroidReport `json:"android"`
			}
			if err := json.Unmarshal([]byte(androidReport), &report); err != nil {
				t.Fatal(err)
			}
			verified := true
			report.Android.Microphone = &diagnostics.Microphone{State: "muted", Route: "built-in microphone",
				SampleRate: 48000, Channels: 1, RequestedRoute: "built-in microphone", RouteVerified: &verified}
			if duplex {
				report.Android.Direction = "duplex"
			}
			ice := iceStatus()
			if continuous {
				ice = continuousBody(0, "phone", 1)
			}
			var body map[string]any
			if err := json.Unmarshal([]byte(ice), &body); err != nil {
				t.Fatal(err)
			}
			body["android"] = report.Android
			payload, err := json.Marshal(body)
			if err != nil {
				t.Fatal(err)
			}
			for i := 0; i < 2; i++ {
				w = postReport(s, s.session, string(payload))
				if w.Code != 200 || !strings.Contains(w.Body.String(), `"report_log":"accepted"`) || s.lastReport != 1 {
					t.Fatalf("muted capture with ICE rejected: duplex=%v continuous=%v: %d %s", duplex, continuous, w.Code, w.Body.String())
				}
			}
			if p.added != 1 || len(p.controls) != 0 || !p.status.MicrophoneMuted {
				t.Fatal("diagnostics changed microphone gate or replayed ICE")
			}
			if err := l.Close("test"); err != nil {
				t.Fatal(err)
			}
			data, err := os.ReadFile(path)
			if err != nil || strings.Count(string(data), `"microphone":{"state":"muted"`) != 1 {
				t.Fatal("retained capture report missing or duplicated", err)
			}
		}
	}
}

func postReport(s *Server, token, body string) *httptest.ResponseRecorder {
	r := httptest.NewRequest("POST", "https://192.168.1.2/status", strings.NewReader(body))
	r.Header.Set("Authorization", "Bearer "+token)
	r.TLS = &tls.ConnectionState{}
	w := httptest.NewRecorder()
	s.ServeHTTP(w, r)
	return w
}

func TestReportsPairBothSidesAndRenewOnlyAuthenticatedSession(t *testing.T) {
	now := time.Now()
	path := filepath.Join(t.TempDir(), "combined.jsonl")
	l, _, err := diagnostics.Create(path, diagnostics.DesktopCapture, now)
	if err != nil {
		t.Fatal(err)
	}
	defer l.Close("test")
	invitation := strings.Repeat("a", 43)
	s := New(&fakePeer{status: rtc.Status{State: "connected", BytesSent: 9876}}, invitation, now, WithDiagnostics(l))
	s.now = func() time.Time { return now }
	credential := claim(t, s, invitation)
	if postReport(s, invitation, androidReport).Code != 401 || postReport(s, credential, androidReport).Code != 409 {
		t.Fatal("report bypassed authorization/answer")
	}
	call(s, "/answer", credential, `{"version":1,"sdp":"answer"}`)
	now = now.Add(10 * time.Second)
	w := postReport(s, credential, androidReport)
	if w.Code != 200 {
		t.Fatalf("report failed: %d %s", w.Code, w.Body.String())
	}
	var response struct {
		ReportLog      string `json:"report_log"`
		ReportSequence int    `json:"report_sequence"`
		BytesSent      int    `json:"bytes_sent"`
	}
	if err := json.Unmarshal(w.Body.Bytes(), &response); err != nil || response.ReportLog != "accepted" || response.ReportSequence != 1 || response.BytesSent != 9876 {
		t.Fatalf("bad acknowledgment: %s", w.Body.String())
	}
	now = now.Add(10 * time.Second)
	if _, err := s.Check(); err != nil {
		t.Fatal("valid report did not renew watchdog")
	}
	if retry := postReport(s, credential, androidReport); retry.Code != 200 || !strings.Contains(retry.Body.String(), `"report_log":"accepted"`) {
		t.Fatal("exact retry lost its acknowledgment")
	}
	if postReport(s, credential, strings.Replace(androidReport, `"buffer_ms":40`, `"buffer_ms":41`, 1)).Code != 409 {
		t.Fatal("conflicting duplicate accepted")
	}
	now = now.Add(6 * time.Second)
	if postReport(s, credential, strings.Replace(androidReport, `"sequence":1`, `"sequence":2`, 1)).Code != 410 {
		t.Fatal("report revived expired session")
	}
	if err := l.Close(s.EndReason()); err != nil {
		t.Fatal(err)
	}
	data, err := os.ReadFile(path)
	if err != nil {
		t.Fatal(err)
	}
	if !strings.Contains(string(data), `"windows":{"state":"connected"`) || !strings.Contains(string(data), `"android":{"sequence":1`) || !strings.Contains(string(data), `"bytes_sent":9876`) || !strings.Contains(string(data), "receiver_timeout") {
		t.Fatalf("missing combined evidence: %s", data)
	}
	if strings.Count(string(data), `"android":{"sequence":1`) != 1 {
		t.Fatal("retry wrote duplicate diagnostics")
	}
	for _, secret := range []string{invitation, credential, "192.168.1.2", `"sdp"`} {
		if strings.Contains(string(data), secret) {
			t.Fatal("control data leaked into log")
		}
	}
}

func TestOutputExtensionReachesCombinedLogAndRejectsUnknownFields(t *testing.T) {
	now := time.Now()
	path := filepath.Join(t.TempDir(), "output.jsonl")
	l, _, err := diagnostics.Create(path, diagnostics.DesktopCapture, now)
	if err != nil {
		t.Fatal(err)
	}
	defer l.Close("test")
	s := New(&fakePeer{status: rtc.Status{State: "connected"}}, strings.Repeat("a", 43), now, WithDiagnostics(l))
	credential := claim(t, s, strings.Repeat("a", 43))
	call(s, "/answer", credential, `{"version":1,"sdp":"answer"}`)
	body := strings.Replace(androidReport, `"metrics":`, outputExtension+`"metrics":`, 1)
	if w := postReport(s, credential, body); w.Code != 200 {
		t.Fatalf("output rejected: %d %s", w.Code, w.Body.String())
	}
	bad := strings.Replace(body, `"sequence":1`, `"sequence":2`, 1)
	bad = strings.Replace(bad, `"route_changes":0`, `"device_address":"secret"`, 1)
	if w := postReport(s, credential, bad); w.Code != 400 {
		t.Fatal("unknown output field accepted")
	}
	if err := l.Close("test"); err != nil {
		t.Fatal(err)
	}
	data, err := os.ReadFile(path)
	if err != nil {
		t.Fatal(err)
	}
	for _, expected := range []string{`"windows":{"state":"connected"`, `"estimated_queue_ms":120`, `"fast_accelerate":true`} {
		if !strings.Contains(string(data), expected) {
			t.Fatalf("combined log missing %s", expected)
		}
	}
	if strings.Contains(string(data), "secret") {
		t.Fatal("unknown field leaked into log")
	}
}

func TestOutputCapabilityIsAdvertisedOnlyWithActiveLogging(t *testing.T) {
	for _, enabled := range []bool{false, true} {
		now := time.Now()
		var log *diagnostics.Log
		if enabled {
			var err error
			log, _, err = diagnostics.Create(filepath.Join(t.TempDir(), "session.jsonl"), diagnostics.DesktopCapture, now)
			if err != nil {
				t.Fatal(err)
			}
			defer log.Close("test")
		}
		s := New(&fakePeer{}, strings.Repeat("a", 43), now, WithDiagnostics(log))
		w := call(s, "/offer", strings.Repeat("a", 43), `{"version":1}`)
		var offer struct {
			Version         int `json:"diagnostics_version"`
			Output          int `json:"output_diagnostics_version"`
			OutputControl   int `json:"output_control_diagnostics_version"`
			MediaTransport  int `json:"media_transport_diagnostics_version"`
			RouteSelection  int `json:"route_selection_diagnostics_version"`
			TLSVerification int `json:"tls_certificate_diagnostics_version"`
		}
		if w.Code != 200 || json.Unmarshal(w.Body.Bytes(), &offer) != nil ||
			(offer.Version == 1) != enabled || (offer.Output == 1) != enabled || (offer.OutputControl == 1) != enabled || (offer.MediaTransport == 1) != enabled || (offer.RouteSelection == 1) != enabled || (offer.TLSVerification == 1) != enabled {
			t.Fatal("incorrect diagnostic capabilities")
		}
	}
}

func TestRouteSelectionRequiresNegotiationBoundsAndNoPrivateFields(t *testing.T) {
	s, l, path, token := diagnosticsSession(t)
	s.peer.(*fakePeer).status.RouteSelection = &rtc.RouteSelection{Version: 1, LocalRenomination: true, RemoteRenomination: true, Negotiated: true, ObservedSwitches: 1}
	const route = `"route_selection":{"version":1,"local_renomination":true,"remote_renomination":true,"negotiated":true,"generation":0,"observed_switches":2},`
	body := strings.Replace(androidReport, `"metrics":`, route+`"metrics":`, 1)
	seen := s.lastSeen
	for _, bad := range []string{
		strings.Replace(body, `"negotiated":true`, `"negotiated":false`, 1),
		strings.Replace(body, `"observed_switches":2`, `"observed_switches":1000001`, 1),
		strings.Replace(body, `"generation":0`, `"generation":-1`, 1),
		strings.Replace(body, `"generation":0`, `"generation":0,"pair_id":"private-pair"`, 1),
	} {
		if postReport(s, token, bad).Code != 400 || s.lastSeen != seen || s.lastReport != 0 {
			t.Fatal("invalid route observation reached log or renewed heartbeat")
		}
	}
	if w := postReport(s, token, body); w.Code != 200 || !strings.Contains(w.Body.String(), `"observed_switches":1`) {
		t.Fatal("host route observation missing", w.Body.String())
	}
	if err := l.Close("test"); err != nil {
		t.Fatal(err)
	}
	data, err := os.ReadFile(path)
	if err != nil {
		t.Fatal(err)
	}
	if !strings.Contains(string(data), `"observed_switches":2`) || strings.Contains(string(data), "private-pair") {
		t.Fatal("Android route evidence missing or private field leaked")
	}
	old, _, _, oldToken := connected(t)
	if postReport(old, oldToken, body).Code != 400 || postReport(old, oldToken, androidReport).Code != 200 {
		t.Fatal("unadvertised route report or legacy compatibility failed")
	}
}

func TestSelectedTransportPairsBothEndpointsAndRejectsPrivateFields(t *testing.T) {
	s, l, path, token := diagnosticsSession(t)
	peer := s.peer.(*fakePeer)
	peer.status.MediaTransport = &rtc.MediaTransport{Version: 1, LocalCandidate: "relay", RemoteCandidate: "relay", CandidateProtocol: "udp", RelayProtocol: "tcp"}
	const transport = `"media_transport":{"version":1,"local_candidate_type":"relay","remote_candidate_type":"relay","candidate_protocol":"udp","relay_protocol":"tls"},`
	body := strings.Replace(androidReport, `"metrics":`, transport+`"metrics":`, 1)
	seen := s.lastSeen
	for _, bad := range []string{
		strings.Replace(body, `"relay_protocol":"tls"`, `"relay_protocol":"turns:private-server"`, 1),
		strings.Replace(body, `"relay_protocol":"tls"`, `"relay_protocol":"not_applicable"`, 1),
		strings.Replace(body, `"relay_protocol":"tls"`, `"relay_protocol":"tls","url":"private-server"`, 1),
	} {
		if postReport(s, token, bad).Code != 400 || s.lastSeen != seen || s.lastReport != 0 {
			t.Fatal("invalid transport reached log or renewed heartbeat")
		}
	}
	if w := postReport(s, token, body); w.Code != 200 || !strings.Contains(w.Body.String(), `"relay_protocol":"tcp"`) {
		t.Fatal("Windows transport missing from status", w.Body.String())
	}
	if err := l.Close("test"); err != nil {
		t.Fatal(err)
	}
	data, err := os.ReadFile(path)
	if err != nil {
		t.Fatal(err)
	}
	// Check the two protocols occupy their own side of one combined record.
	var found bool
	for _, line := range strings.Split(string(data), "\n") {
		var record struct {
			Windows *rtc.Status                `json:"windows"`
			Android *diagnostics.AndroidReport `json:"android"`
		}
		if json.Unmarshal([]byte(line), &record) == nil && record.Android != nil {
			found = record.Windows != nil && record.Windows.MediaTransport != nil &&
				record.Android.MediaTransport != nil && record.Windows.MediaTransport.RelayProtocol == "tcp" &&
				record.Android.MediaTransport.RelayProtocol == "tls"
		}
	}
	if !found || strings.Contains(string(data), "private-server") {
		t.Fatal("combined transport evidence missing or leaked private data")
	}
	old, _, _, oldToken := connected(t)
	if postReport(old, oldToken, body).Code != 400 || postReport(old, oldToken, androidReport).Code != 200 {
		t.Fatal("unadvertised transport or legacy report compatibility failed")
	}
}

func TestBadReportsCannotReachLogOrRenewHeartbeat(t *testing.T) {
	bad := []string{
		`{}`, `{"version":1,"android":null}`, strings.Repeat(" ", diagnostics.MaxReportBody) + androidReport,
		androidReport + ` {}`, strings.Replace(androidReport, `"version":1`, `"version":2`, 1),
		strings.Replace(androidReport, `"sequence":1`, `"sequence":0`, 1),
		strings.Replace(androidReport, `"buffer_ms":40`, `"host_address":"secret-ip"`, 1),
		strings.Replace(androidReport, `"buffer_ms":40`, `"buffer_ms":-1`, 1),
		strings.Replace(androidReport, `"buffer_ms":40`, `"buffer_ms":1e309`, 1),
		strings.Replace(androidReport, `"model":"Phone"`, `"sdp":"secret-sdp"`, 1),
		strings.Replace(androidReport, `"model":"Phone"`, `"model":"line\nbreak"`, 1),
		strings.Replace(androidReport, `"model":"Phone"`, `"model":"`+strings.Repeat("x", 81)+`"`, 1),
		strings.Replace(androidReport, `"Bluetooth A2DP media"`, `"secret-device-address"`, 1),
		strings.Replace(androidReport, `"path":"direct / udp"`, `"path":"secret-peer"`, 1),
	}
	for i, body := range bad {
		now := time.Now()
		s := New(&fakePeer{}, strings.Repeat("a", 43), now)
		s.now = func() time.Time { return now }
		credential := claim(t, s, strings.Repeat("a", 43))
		call(s, "/answer", credential, `{"version":1,"sdp":"answer"}`)
		now = now.Add(10 * time.Second)
		if code := postReport(s, credential, body).Code; code != 400 || s.lastReport != 0 {
			t.Fatalf("bad report %d accepted: %d", i, code)
		}
		now = now.Add(6 * time.Second)
		if _, err := s.Check(); err == nil {
			t.Fatalf("bad report %d renewed heartbeat", i)
		}
	}
}

func TestReportingUnavailableDoesNotBreakPlayback(t *testing.T) {
	for _, closedLog := range []bool{false, true} {
		now := time.Now()
		var l *diagnostics.Log
		if closedLog {
			var err error
			l, _, err = diagnostics.Create(filepath.Join(t.TempDir(), "session.jsonl"), diagnostics.DesktopCapture, now)
			if err != nil {
				t.Fatal(err)
			}
			if err := l.Close("test"); err != nil {
				t.Fatal(err)
			}
		}
		s := New(&fakePeer{status: rtc.Status{State: "connected"}}, strings.Repeat("a", 43), now, WithDiagnostics(l))
		s.now = func() time.Time { return now }
		credential := claim(t, s, strings.Repeat("a", 43))
		call(s, "/answer", credential, `{"version":1,"sdp":"answer"}`)
		now = now.Add(10 * time.Second)
		w := postReport(s, credential, androidReport)
		if w.Code != 200 || strings.Contains(w.Body.String(), `"report_log":"accepted"`) {
			t.Fatalf("log failure broke status or claimed success: %s", w.Body.String())
		}
		now = now.Add(10 * time.Second)
		if _, err := s.Check(); err != nil {
			t.Fatal("logging failure broke heartbeat")
		}
		if call(s, "/status", credential, "").Code != 200 || call(s, "/stop", credential, "{}").Code != 200 || s.EndReason() != "receiver_stop" {
			t.Fatal("legacy client/stop broke")
		}
	}
}
