package session

import (
	"encoding/json"
	"errors"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"

	"github.com/maskarauder/MicDrop/internal/diagnostics"
	"github.com/maskarauder/MicDrop/internal/rtc"
)

type microphonePeer struct {
	cyclePeer
	controls    []bool
	failControl bool
}

func (p *microphonePeer) SetMicrophoneMuted(muted bool) error {
	p.controls = append(p.controls, muted)
	if p.failControl {
		return errors.New("endpoint failed")
	}
	p.status.MicrophoneMuted = muted
	return nil
}

type microphoneAuthority struct{}

func (microphoneAuthority) Client(r *http.Request) (string, bool) {
	client := r.Header.Get("X-Test-Verified-Identity")
	return client, client == "phone" || client == "other"
}
func (microphoneAuthority) Allowed(string) bool                               { return true }
func (microphoneAuthority) Enrollment(w http.ResponseWriter, _ *http.Request) { w.WriteHeader(404) }
func microphoneCall(h *Host, client, path, token, body string) *httptest.ResponseRecorder {
	r := httptest.NewRequest("POST", "https://192.168.1.2"+path, strings.NewReader(body))
	r.Header.Set("X-Test-Verified-Identity", client)
	if token != "" {
		r.Header.Set("Authorization", "Bearer "+token)
	}
	w := httptest.NewRecorder()
	h.ServeHTTP(w, r)
	return w
}
func microphoneHost(t *testing.T) (*Host, *microphonePeer, *int) {
	t.Helper()
	playbackCalls := new(int)
	h, err := NewPairedHost(microphoneAuthority{}, func(time.Time, OfferOptions) (Resources, error) {
		(*playbackCalls)++
		return Resources{Peer: &cyclePeer{}}, nil
	})
	if err != nil {
		t.Fatal(err)
	}
	p := &microphonePeer{cyclePeer: cyclePeer{fakePeer: fakePeer{status: rtc.Status{
		State: "connected", Direction: "phone_microphone", MicrophoneMuted: true}}}}
	h.EnableMicrophoneReturn(func(time.Time, OfferOptions) (Resources, error) { return Resources{Peer: p}, nil })
	t.Cleanup(func() { h.Close("test") })
	return h, p, playbackCalls
}
func microphoneClaim(t *testing.T, h *Host) (string, *managedSession) {
	t.Helper()
	w := microphoneCall(h, "phone", "/offer", "", `{"version":3,"microphone_return_version":1}`)
	var result struct {
		Session    string
		Direction  string `json:"audio_direction"`
		Capability int    `json:"microphone_return_version"`
	}
	if w.Code != 200 || json.Unmarshal(w.Body.Bytes(), &result) != nil || len(result.Session) != 43 || result.Direction != "phone_microphone" || result.Capability != 1 {
		t.Fatalf("offer: %d %s", w.Code, w.Body.String())
	}
	h.mu.Lock()
	current := h.active
	h.mu.Unlock()
	return result.Session, current
}
func TestMicrophoneRequiresFreshPairedDirectionAndSessionOwner(t *testing.T) {
	h, p, playback := microphoneHost(t)
	for _, body := range []string{`{"version":3,"microphone_return_version":2}`, `{"version":2,"microphone_return_version":1}`, `{"version":3,"microphone_return_version":true}`} {
		if microphoneCall(h, "phone", "/offer", "", body).Code != 400 || p.offers != 0 {
			t.Fatal("invalid direction allocated native peer")
		}
	}
	if microphoneCall(h, "unknown", "/offer", "", `{"version":3,"microphone_return_version":1}`).Code != 403 {
		t.Fatal("unpaired phone allowed")
	}
	token, _ := microphoneClaim(t, h)
	if *playback != 0 || p.status.MicrophoneMuted != true || len(p.controls) != 0 {
		t.Fatal("microphone session opened playback or unmuted implicitly")
	}
	if microphoneCall(h, "phone", "/microphone", token, `{"version":3,"muted":false}`).Code != 409 {
		t.Fatal("mute control accepted before answer")
	}
	if microphoneCall(h, "other", "/answer", token, `{"version":3,"sdp":"answer"}`).Code != 403 {
		t.Fatal("other paired phone stole answer")
	}
	if microphoneCall(h, "phone", "/answer", token, `{"version":3,"sdp":"answer"}`).Code != 200 {
		t.Fatal("answer")
	}
	if microphoneCall(h, "other", "/microphone", token, `{"version":3,"muted":false}`).Code != 403 ||
		microphoneCall(h, "phone", "/microphone", strings.Repeat("x", 43), `{"version":3,"muted":false}`).Code != 401 || len(p.controls) != 0 {
		t.Fatal("unauthorized control reached bridge")
	}
	for _, body := range []string{`{"version":3}`, `{"version":3,"muted":null}`, `{"version":3,"muted":1}`, `{"version":2,"muted":false}`, `{"version":3,"muted":false,"input":"secret"}`, strings.Repeat(" ", 1024) + `{"version":3,"muted":false}`} {
		if microphoneCall(h, "phone", "/microphone", token, body).Code != 400 || len(p.controls) != 0 {
			t.Fatal("malformed microphone control")
		}
	}
	for _, muted := range []bool{false, true, false} {
		body, _ := json.Marshal(map[string]any{"version": 3, "muted": muted})
		if microphoneCall(h, "phone", "/microphone", token, string(body)).Code != 200 || p.status.MicrophoneMuted != muted {
			t.Fatal("authorized control")
		}
	}
	if len(p.controls) != 3 {
		t.Fatal("unexpected control count")
	}
}
func TestMicrophoneNotConfiguredAndLegacyCannotAllocateReturn(t *testing.T) {
	calls := 0
	factory := func(time.Time, OfferOptions) (Resources, error) { calls++; return Resources{Peer: &cyclePeer{}}, nil }
	h, err := NewPairedHost(microphoneAuthority{}, factory)
	if err != nil {
		t.Fatal(err)
	}
	defer h.Close("test")
	if microphoneCall(h, "phone", "/offer", "", `{"version":3,"microphone_return_version":1}`).Code != 409 || calls != 0 {
		t.Fatal("unconfigured host allocated resources")
	}
	legacy := NewHost(reusableToken, time.Now().Add(time.Hour), factory)
	legacy.EnableMicrophoneReturn(factory)
	defer legacy.Close("test")
	if hostCall(legacy, "POST", "/offer", reusableToken, `{"version":2,"microphone_return_version":1}`).Code != 400 || calls != 0 {
		t.Fatal("legacy token opened microphone return")
	}
}
func TestMicrophoneBridgeFailureStopsOnlyItsSession(t *testing.T) {
	h, p, _ := microphoneHost(t)
	token, current := microphoneClaim(t, h)
	microphoneCall(h, "phone", "/answer", token, `{"version":3,"sdp":"answer"}`)
	p.failControl = true
	if microphoneCall(h, "phone", "/microphone", token, `{"version":3,"muted":false}`).Code != 500 {
		t.Fatal("bridge failure hidden")
	}
	waitSession(t, current)
	if p.closes.Load() != 1 || current.server.EndReason() != "microphone_bridge_failed" {
		t.Fatal("failed bridge retained resources")
	}
	if microphoneCall(h, "phone", "/offer", "", `{"version":3}`).Code != 200 {
		t.Fatal("bridge failure ended listener")
	}
}
func TestMicrophoneControlCannotExtendHeartbeatOrReviveSession(t *testing.T) {
	h, p, _ := microphoneHost(t)
	now := time.Now()
	h.now = func() time.Time { return now }
	token, current := microphoneClaim(t, h)
	microphoneCall(h, "phone", "/answer", token, `{"version":3,"sdp":"answer"}`)
	now = now.Add(10 * time.Second)
	if microphoneCall(h, "phone", "/microphone", token, `{"version":3,"muted":true}`).Code != 200 {
		t.Fatal("control")
	}
	now = now.Add(6 * time.Second)
	if microphoneCall(h, "phone", "/microphone", token, `{"version":3,"muted":false}`).Code != 410 || len(p.controls) != 1 {
		t.Fatal("control revived dead session")
	}
	waitSession(t, current)
}
func TestMicrophoneStatusFailureAndRevocationReleaseReturn(t *testing.T) {
	for _, revoked := range []bool{false, true} {
		h, p, _ := microphoneHost(t)
		token, current := microphoneClaim(t, h)
		microphoneCall(h, "phone", "/answer", token, `{"version":3,"sdp":"answer"}`)
		if revoked {
			h.Revoke("phone")
		} else {
			p.status.BridgeFailed = true
			h.Check()
		}
		waitSession(t, current)
		if p.closes.Load() != 1 {
			t.Fatal("bridge remained open")
		}
		if !revoked && current.server.EndReason() != "microphone_bridge_failed" {
			t.Fatal("lost bridge failure reason")
		}
	}
}

func TestMicrophoneReportsCombineDirectionsAndRejectMismatches(t *testing.T) {
	h, p, _ := microphoneHost(t)
	path := filepath.Join(t.TempDir(), "microphone.jsonl")
	l, _, err := diagnostics.Create(path, diagnostics.PhoneMicrophone, time.Now())
	if err != nil {
		t.Fatal(err)
	}
	h.microphoneFactory = func(time.Time, OfferOptions) (Resources, error) { return Resources{Peer: p, Log: l}, nil }
	p.status.ReturnPackets = 321
	p.status.BridgeFrames = 48000
	token, current := microphoneClaim(t, h)
	microphoneCall(h, "phone", "/answer", token, `{"version":3,"sdp":"answer"}`)
	legacy := strings.Replace(androidReport, `"version":1`, `"version":3`, 1)
	if microphoneCall(h, "phone", "/status", token, legacy).Code != 400 {
		t.Fatal("mic session accepted playback-only diagnostics")
	}
	body := strings.Replace(legacy, `"metrics":`, `"microphone":{"state":"running","route":"built-in microphone","sample_rate_hz":48000,"channels":1},"metrics":`, 1)
	if microphoneCall(h, "phone", "/status", token, strings.Replace(body, `"channels":1`, `"channels":1,"device_name":"secret"`, 1)).Code != 400 {
		t.Fatal("unknown microphone identifier accepted")
	}
	body = strings.Replace(body, `"metrics":{`, `"metrics":{"sent_bytes_total":8000,`, 1)
	if w := microphoneCall(h, "phone", "/status", token, body); w.Code != 200 || !strings.Contains(w.Body.String(), `"report_log":"accepted"`) {
		t.Fatalf("mic report: %d %s", w.Code, w.Body.String())
	}
	microphoneCall(h, "phone", "/stop", token, `{"reason":"user_stop"}`)
	waitSession(t, current)
	data, err := os.ReadFile(path)
	if err != nil {
		t.Fatal(err)
	}
	for _, expected := range []string{`"microphone":{"state":"running"`, `"sent_bytes_total":8000`, `"return_packets_received":321`, `"bridge_frames_submitted":48000`} {
		if !strings.Contains(string(data), expected) {
			t.Fatalf("combined log lacks %s", expected)
		}
	}
	if strings.Contains(string(data), "secret") || strings.Contains(string(data), token) {
		t.Fatal("private control data entered log")
	}
	w := microphoneCall(h, "phone", "/offer", "", `{"version":3}`)
	var offer struct{ Session string }
	if w.Code != 200 || json.Unmarshal(w.Body.Bytes(), &offer) != nil {
		t.Fatal("normal playback offer")
	}
	microphoneCall(h, "phone", "/answer", offer.Session, `{"version":3,"sdp":"answer"}`)
	if microphoneCall(h, "phone", "/status", offer.Session, body).Code != 400 ||
		microphoneCall(h, "phone", "/microphone", offer.Session, `{"version":3,"muted":false}`).Code != 409 {
		t.Fatal("playback session accepted microphone report/control")
	}
}
