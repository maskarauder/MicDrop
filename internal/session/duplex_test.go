package session

import (
	"encoding/json"
	"net/http"
	"os"
	"strings"
	"testing"
	"time"

	"github.com/maskarauder/MicDrop/internal/diagnostics"
	"github.com/maskarauder/MicDrop/internal/rtc"
)

const duplexOffer = `{"version":3,"microphone_return_version":1,"duplex_version":1}`

func duplexClaim(t *testing.T, h *Host) (string, *managedSession) {
	t.Helper()
	w := microphoneCall(h, "phone", "/offer", "", duplexOffer)
	var reply struct {
		Session    string
		Direction  string `json:"audio_direction"`
		Microphone int    `json:"microphone_return_version"`
		Duplex     int    `json:"duplex_version"`
	}
	if w.Code != 200 || json.Unmarshal(w.Body.Bytes(), &reply) != nil || len(reply.Session) != 43 ||
		reply.Direction != "duplex" || reply.Microphone != 1 || reply.Duplex != 1 {
		t.Fatalf("duplex offer: %d %s", w.Code, w.Body.String())
	}
	h.mu.Lock()
	current := h.active
	h.mu.Unlock()
	return reply.Session, current
}

func TestDuplexRequiresExplicitPairedCapabilitiesWithoutDowngrade(t *testing.T) {
	h, p, playback := microphoneHost(t)
	duplexCalls := 0
	for _, body := range []string{
		`{"version":3,"duplex_version":1}`, `{"version":3,"microphone_return_version":1,"duplex_version":2}`,
		`{"version":3,"microphone_return_version":1,"duplex_version":true}`,
		`{"version":2,"microphone_return_version":1,"duplex_version":1}`,
		`{"version":3,"microphone_return_version":1,"duplex_version":-1}`,
	} {
		if microphoneCall(h, "phone", "/offer", "", body).Code != 400 {
			t.Fatal("invalid duplex request accepted")
		}
	}
	if microphoneCall(h, "phone", "/offer", "", duplexOffer).Code != 409 || *playback != 0 || p.offers != 0 {
		t.Fatal("unconfigured duplex silently opened another direction")
	}
	d := &microphonePeer{cyclePeer: cyclePeer{fakePeer: fakePeer{status: rtc.Status{State: "connected", Direction: "duplex", MicrophoneMuted: true}}}}
	h.EnableDuplex(func(time.Time, OfferOptions) (Resources, error) { duplexCalls++; return Resources{Peer: d}, nil })
	if microphoneCall(h, "unknown", "/offer", "", duplexOffer).Code != 403 || duplexCalls != 0 {
		t.Fatal("unpaired phone allocated duplex")
	}
	token, current := duplexClaim(t, h)
	if duplexCalls != 1 || *playback != 0 || p.offers != 0 || !d.status.MicrophoneMuted || len(d.controls) != 0 {
		t.Fatal("duplex allocated separate playback/mic sessions or implicitly unmuted")
	}
	if microphoneCall(h, "other", "/answer", token, `{"version":3,"sdp":"answer"}`).Code != 403 ||
		microphoneCall(h, "phone", "/microphone", token, `{"version":3,"muted":false}`).Code != 409 {
		t.Fatal("duplex bypassed identity or answer requirement")
	}
	if microphoneCall(h, "phone", "/answer", token, `{"version":3,"sdp":"answer"}`).Code != 200 ||
		microphoneCall(h, "other", "/microphone", token, `{"version":3,"muted":false}`).Code != 403 {
		t.Fatal("duplex control owner mismatch")
	}
	for _, muted := range []bool{false, true, false} {
		body, _ := json.Marshal(map[string]any{"version": 3, "muted": muted})
		if microphoneCall(h, "phone", "/microphone", token, string(body)).Code != 200 || d.status.MicrophoneMuted != muted {
			t.Fatal("duplex microphone control")
		}
	}
	if microphoneCall(h, "other", "/stop", token, `{"reason":"user_stop"}`).Code != 403 || d.closes.Load() != 0 {
		t.Fatal("another phone stopped duplex")
	}
	microphoneCall(h, "phone", "/stop", token, `{"reason":"user_stop"}`)
	waitSession(t, current)
	if d.closes.Load() != 1 || current.server.EndReason() != "receiver_stop" {
		t.Fatal("duplex teardown")
	}
	microphoneClaim(t, h)
	if p.offers != 1 || duplexCalls != 1 {
		t.Fatal("later return-only request retained duplex mode")
	}
}

func TestDuplexLogsCombinePlaybackOutputAndMicrophoneCounters(t *testing.T) {
	h, p, _ := microphoneHost(t)
	l, path, err := diagnostics.CreateInDirectory(t.TempDir(), diagnostics.DuplexCapture, time.Now())
	if err != nil {
		t.Fatal(err)
	}
	p.status.Direction = "duplex"
	p.status.PCMFramesSent = 48000
	p.status.ReturnPackets = 123
	p.status.BridgeFrames = 48000
	h.EnableDuplex(func(time.Time, OfferOptions) (Resources, error) { return Resources{Peer: p, Log: l}, nil })
	token, current := duplexClaim(t, h)
	microphoneCall(h, "phone", "/answer", token, `{"version":3,"sdp":"answer"}`)
	base := strings.Replace(androidReport, `"version":1`, `"version":3`, 1)
	mic := `"microphone":{"state":"running","route":"built-in microphone","sample_rate_hz":48000,"channels":1},`
	withoutDirection := strings.Replace(base, `"metrics":`, mic+`"metrics":`, 1)
	for _, bad := range []string{base, withoutDirection, strings.Replace(withoutDirection, `"metrics":`, `"audio_direction":"desktop_playback","metrics":`, 1)} {
		if microphoneCall(h, "phone", "/status", token, bad).Code != 400 {
			t.Fatal("duplex accepted wrong-mode diagnostics")
		}
	}
	body := strings.Replace(withoutDirection, `"metrics":`, outputExtension+`"audio_direction":"duplex","metrics":`, 1)
	body = strings.Replace(body, `"metrics":{`, `"metrics":{"sent_bytes_total":8000,`, 1)
	if w := microphoneCall(h, "phone", "/status", token, body); w.Code != 200 {
		t.Fatalf("combined report: %d %s", w.Code, w.Body.String())
	}
	microphoneCall(h, "phone", "/stop", token, `{"reason":"user_stop"}`)
	waitSession(t, current)
	data, err := os.ReadFile(path)
	if err != nil {
		t.Fatal(err)
	}
	for _, expected := range []string{`"audio_direction":"duplex"`, `"playback":"receiver_managed"`, `"phone_microphone":"requested"`,
		`"pcm_frames_sent":48000`, `"return_packets_received":123`, `"sent_bytes_total":8000`, `"buffer_ms":40`, `"output":{"backend":"webrtc_audiotrack"`, `"reason":"receiver_stop"`} {
		if !strings.Contains(string(data), expected) {
			t.Fatalf("combined log missing %s", expected)
		}
	}
	if strings.Contains(string(data), token) {
		t.Fatal("session credential leaked")
	}
}

func TestDuplexFailureEndsBothDirectionsAndListenerAcceptsPlayback(t *testing.T) {
	for _, failure := range []string{"capture", "bridge", "watchdog", "revocation"} {
		t.Run(failure, func(t *testing.T) {
			h, p, playback := microphoneHost(t)
			h.EnableDuplex(func(time.Time, OfferOptions) (Resources, error) { return Resources{Peer: p}, nil })
			now := time.Now()
			h.now = func() time.Time { return now }
			token, current := duplexClaim(t, h)
			microphoneCall(h, "phone", "/answer", token, `{"version":3,"sdp":"answer"}`)
			expected := "audio_session_lost"
			switch failure {
			case "capture":
				p.status.CaptureFailed = true
			case "bridge":
				p.status.BridgeFailed = true
				expected = "microphone_bridge_failed"
			case "watchdog":
				now = now.Add(16 * time.Second)
				expected = "receiver_timeout"
			case "revocation":
				h.Revoke("phone")
				expected = "device_revoked"
			}
			h.Check()
			waitSession(t, current)
			if p.closes.Load() != 1 || current.server.EndReason() != expected {
				t.Fatalf("teardown: %s closes=%d", current.server.EndReason(), p.closes.Load())
			}
			if microphoneCall(h, "phone", "/microphone", token, `{"version":3,"muted":false}`).Code != 410 {
				t.Fatal("ended duplex revived")
			}
			if microphoneCall(h, "other", "/offer", "", `{"version":3}`).Code != http.StatusOK || *playback != 1 {
				t.Fatal("duplex failure stopped listener or retained microphone mode")
			}
		})
	}
}
