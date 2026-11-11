package session

import (
	"crypto/tls"
	"encoding/json"
	"github.com/maskarauder/MicDrop/internal/rtc"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
	"time"
)

type continuousPeer struct {
	tricklePeer
	removed int
	enabled bool
}

func (p *continuousPeer) ContinuousICE() bool              { return p.enabled }
func (p *continuousPeer) ForceRelay() bool                 { return false }
func (p *continuousPeer) RemoveICE(rtc.ICECandidate) error { p.removed++; return nil }
func (p *continuousPeer) RestartOffer() (string, error) {
	p.restarts++
	p.local = strings.ReplaceAll(trickleDescription, "host", "host-new")
	return p.local, nil
}

func continuousOffer(h http.Handler, token string, enabled bool) *httptest.ResponseRecorder {
	r := httptest.NewRequest("POST", "https://paired.test/offer", strings.NewReader(`{"version":3}`))
	if token != "" {
		r.Header.Set("Authorization", "Bearer "+token)
	}
	r.TLS = &tls.ConnectionState{}
	r.Header.Set("X-Test-Verified-Identity", "phone")
	r.Header.Set("X-MicDrop-Trickle-ICE", "1")
	if enabled {
		r.Header.Set(rtc.ContinuousHeader, "1")
	}
	w := httptest.NewRecorder()
	h.ServeHTTP(w, r)
	return w
}
func newContinuousSession(t *testing.T) (*Server, *continuousPeer, string) {
	t.Helper()
	p := &continuousPeer{enabled: true}
	p.local = trickleDescription
	p.status.State = "connected"
	s := New(p, strings.Repeat("a", 43), time.Now())
	s.version = 3
	w := continuousOffer(s, s.invitation, true)
	var offer struct {
		Session    string
		Continuous int `json:"continuous_ice_version"`
		Trickle    int `json:"trickle_ice_version"`
	}
	if w.Code != 200 || json.Unmarshal(w.Body.Bytes(), &offer) != nil || offer.Continuous != 1 || offer.Trickle != 1 || s.trickle != nil {
		t.Fatal("negotiation", w.Code, w.Body.String())
	}
	answer, _ := json.Marshal(map[string]any{"version": 3, "sdp": phoneDescription})
	if call(s, "/answer", offer.Session, string(answer)).Code != 200 {
		t.Fatal("answer")
	}
	return s, p, offer.Session
}
func continuousBody(generation uint64, user string, count int) string {
	cs := []rtc.ICECandidate{}
	if count > 0 {
		cs = append(cs, rtc.ICECandidate{MID: "0", Index: 0, Ufrag: user, Candidate: "candidate:p 1 udp 123 192.0.2.2 5001 typ host"})
	}
	b, _ := json.Marshal(map[string]any{"version": 3, "continuous_ice": rtc.ICESnapshot{Version: 1, Generation: generation, Revision: 1, Candidates: &cs}})
	return string(b)
}
func TestContinuousSessionResetsOnlyAfterNewAnswerAndRejectsOldUpdates(t *testing.T) {
	s, p, token := newContinuousSession(t)
	old := continuousBody(0, "phone", 1)
	for i := 0; i < 2; i++ {
		w := trickleCall(s, "", "/status", token, old)
		if w.Code != 200 {
			t.Fatal(w.Code, w.Body.String())
		}
	}
	if p.added != 1 {
		t.Fatal("duplicate application")
	}
	removed := strings.Replace(continuousBody(0, "phone", 0), `"revision":1`, `"revision":2`, 1)
	if trickleCall(s, "", "/status", token, removed).Code != 200 || p.removed != 1 || len(p.controls) != 0 {
		t.Fatal("removal changed controls or failed")
	}
	if call(s, "/recover-offer", token, firstRestart).Code != 200 {
		t.Fatal("restart")
	}
	current := continuousBody(1, "phone-new", 1)
	if trickleCall(s, "", "/status", token, old).Code != 400 || trickleCall(s, "", "/status", token, current).Code != 400 || p.added != 1 {
		t.Fatal("candidate while answer pending")
	}
	answer, _ := json.Marshal(map[string]any{"version": 3, "generation": 1, "sdp": strings.ReplaceAll(phoneDescription, "phone", "phone-new")})
	if call(s, "/recover-answer", token, string(answer)).Code != 200 {
		t.Fatal("recovery answer")
	}
	if trickleCall(s, "", "/status", token, old).Code != 400 || trickleCall(s, "", "/status", token, current).Code != 200 || p.added != 2 {
		t.Fatal("generation binding")
	}
	if s.continuous.Generation != 1 || s.continuous.Revision != 1 || s.recovery.generation != 1 {
		t.Fatal("exchange not reset")
	}
	call(s, "/stop", token, `{"reason":"user_stop"}`)
	if trickleCall(s, "", "/status", token, current).Code == 200 || p.added != 2 {
		t.Fatal("late update after stop")
	}
}
func TestContinuousCapabilityFallsBackAndCannotBypassExpiry(t *testing.T) {
	for _, enabled := range []bool{false, true} {
		p := &continuousPeer{enabled: enabled}
		s := New(p, strings.Repeat("a", 43), time.Now())
		s.version = 3
		w := continuousOffer(s, s.invitation, !enabled)
		if w.Code != 200 || s.continuous != nil || s.trickle == nil {
			t.Fatal("legacy fallback", w.Code)
		}
	}
	s, p, token := newContinuousSession(t)
	s.disconnectedAt = s.now().Add(-31 * time.Second)
	if trickleCall(s, "", "/status", token, continuousBody(0, "phone", 1)).Code != 410 || p.added != 0 {
		t.Fatal("expired candidate accepted")
	}
}

func TestContinuousPolicyReachesFactoryOnlyFromAuthenticatedCapability(t *testing.T) {
	for _, enabled := range []bool{false, true} {
		calls := 0
		h, err := NewPairedHost(microphoneAuthority{}, func(_ time.Time, options OfferOptions) (Resources, error) {
			calls++
			if options.ContinuousICE != enabled {
				t.Fatal("creation policy differs from negotiation")
			}
			p := &continuousPeer{enabled: options.ContinuousICE}
			p.local = trickleDescription
			p.status.State = "connected"
			return Resources{Peer: p}, nil
		})
		if err != nil {
			t.Fatal(err)
		}
		if w := continuousOffer(h, strings.Repeat("x", 43), enabled); w.Code != 401 || calls != 0 {
			t.Fatal("allocated before authorization")
		}
		if w := continuousOffer(h, "", enabled); w.Code != 200 || calls != 1 {
			t.Fatal("capability negotiation", w.Code, w.Body.String())
		}
		h.Close("test")
	}
}

func TestContinuousOldConnectedPairCannotClearRecoveryOrReopenMicrophone(t *testing.T) {
	s, p, token := newContinuousSession(t)
	if call(s, "/recover-offer", token, firstRestart).Code != 200 {
		t.Fatal("restart")
	}
	answer, _ := json.Marshal(map[string]any{"version": 3, "generation": 1, "sdp": strings.ReplaceAll(phoneDescription, "phone", "phone-new")})
	if call(s, "/recover-answer", token, string(answer)).Code != 200 {
		t.Fatal("answer")
	}
	started := s.disconnectedAt
	// Model the return gate on this same restart-capable fake peer.
	s.microphone = true
	if call(s, "/status", token, "").Code != 200 || s.disconnectedAt != started || s.recovery.mediaReady {
		t.Fatal("old connected route cleared the interruption")
	}
	if call(s, "/microphone", token, `{"version":3,"muted":false}`).Code != 409 || len(p.controls) != 0 {
		t.Fatal("old route reopened microphone")
	}
	p.status.ICEGenerationCurrent = true
	if call(s, "/status", token, "").Code != 200 || !s.disconnectedAt.IsZero() || !s.recovery.mediaReady {
		t.Fatal("current route not accepted")
	}
	if call(s, "/microphone", token, `{"version":3,"muted":false}`).Code != 200 {
		t.Fatal("current route gate unavailable")
	}
	// A connected old pair never stretches the original thirty-second deadline.
	s.disconnectedAt = s.now().Add(-31 * time.Second)
	p.status.ICEGenerationCurrent = false
	if call(s, "/status", token, "").Code != 410 {
		t.Fatal("old route bypassed expiry")
	}
}
