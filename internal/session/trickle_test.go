package session

import (
	"crypto/tls"
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
	"time"

	"github.com/maskarauder/MicDrop/internal/rtc"
)

const trickleDescription = "v=0\r\nm=audio 9 UDP/TLS/RTP/SAVPF 111\r\na=mid:0\r\na=ice-ufrag:host\r\n"
const phoneDescription = "v=0\r\nm=audio 9 UDP/TLS/RTP/SAVPF 111\r\na=mid:0\r\na=ice-ufrag:phone\r\n"

type tricklePeer struct {
	restartPeer
	trickleOffers, added int
	local                string
}

func (p *tricklePeer) TrickleOffer() (string, error) {
	p.trickleOffers++
	return trickleDescription, nil
}
func (p *tricklePeer) LocalICE() (string, bool, error) { return p.local, true, nil }
func (p *tricklePeer) AddICE(rtc.ICECandidate) error   { p.added++; return nil }
func trickleCall(h http.Handler, client, path, token, body string) *httptest.ResponseRecorder {
	r := httptest.NewRequest("POST", "https://192.0.2.1"+path, strings.NewReader(body))
	r.TLS = &tls.ConnectionState{}
	r.Header.Set("X-Test-Verified-Identity", client)
	if token != "" {
		r.Header.Set("Authorization", "Bearer "+token)
	}
	if path == "/offer" {
		r.Header.Set("X-MicDrop-Trickle-ICE", "1")
	}
	w := httptest.NewRecorder()
	h.ServeHTTP(w, r)
	return w
}
func newTrickleSession(t *testing.T) (*Server, *tricklePeer, string) {
	t.Helper()
	p := &tricklePeer{local: trickleDescription + "a=candidate:h 1 udp 123 192.0.2.1 5000 typ host\r\n"}
	p.status.State = "connected"
	s := New(p, strings.Repeat("a", 43), time.Now())
	s.version = 3
	w := trickleCall(s, "", "/offer", s.invitation, `{"version":3}`)
	var offer struct {
		Session string
		Trickle int `json:"trickle_ice_version"`
	}
	if json.Unmarshal(w.Body.Bytes(), &offer) != nil || w.Code != 200 || offer.Trickle != 1 || p.trickleOffers != 1 || p.offers != 0 {
		t.Fatal("negotiation", w.Code)
	}
	answer, _ := json.Marshal(map[string]any{"version": 3, "sdp": phoneDescription})
	if call(s, "/answer", offer.Session, string(answer)).Code != 200 {
		t.Fatal("answer")
	}
	return s, p, offer.Session
}
func iceStatus() string {
	return `{"version":3,"ice":{"version":1,"generation":0,"ack":0,"offset":0,"complete":true,"candidates":[{"mid":"0","index":0,"ufrag":"phone","candidate":"candidate:p 1 udp 123 192.0.2.2 5001 typ host"}]}}`
}

func TestTrickleHeartbeatRetainsCandidateUntilAcknowledged(t *testing.T) {
	s, p, token := newTrickleSession(t)
	for i := 0; i < 2; i++ {
		w := trickleCall(s, "", "/status", token, iceStatus())
		var reply struct {
			ICE     rtc.ICEDelta       `json:"ice"`
			Trickle *rtc.TrickleStatus `json:"trickle_ice"`
		}
		if w.Code != 200 || json.Unmarshal(w.Body.Bytes(), &reply) != nil || len(reply.ICE.Candidates) != 1 || reply.ICE.Ack != 1 || p.added != 1 || reply.Trickle == nil {
			t.Fatal("retry", w.Code, w.Body.String())
		}
	}
	if trickleCall(s, "", "/status", strings.Repeat("x", 43), iceStatus()).Code != 401 || p.added != 1 {
		t.Fatal("unauthorized")
	}
	if len(p.controls) != 0 {
		t.Fatal("ICE changed microphone gate")
	}
}
func TestTrickleCannotSurviveStopRestartOrExpiredRecovery(t *testing.T) {
	for _, action := range []string{"stop", "restart", "expiry"} {
		s, p, token := newTrickleSession(t)
		switch action {
		case "stop":
			call(s, "/stop", token, `{"reason":"user_stop"}`)
		case "restart":
			if call(s, "/recover-offer", token, firstRestart).Code != 200 {
				t.Fatal("restart")
			}
		case "expiry":
			s.disconnectedAt = s.now().Add(-31 * time.Second)
		}
		if trickleCall(s, "", "/status", token, iceStatus()).Code == 200 || p.added != 0 {
			t.Fatal("late candidate after", action)
		}
	}
}
func TestTrickleIsOptInAndMalformedStatusDoesNotReachNative(t *testing.T) {
	p := &tricklePeer{}
	s := New(p, strings.Repeat("a", 43), time.Now())
	s.version = 3
	if call(s, "/offer", s.invitation, `{"version":3}`).Code != 200 || p.trickleOffers != 0 || p.offers != 1 {
		t.Fatal("legacy changed")
	}
	for _, bad := range []string{strings.Replace(iceStatus(), `"ufrag":"phone"`, `"ufrag":"old"`, 1),
		strings.Replace(iceStatus(), `"generation":0`, `"generation":1`, 1),
		strings.Replace(iceStatus(), `"ice":`, `"android":{},"ice":`, 1)} {
		s, p, token := newTrickleSession(t)
		if trickleCall(s, "", "/status", token, bad).Code != 400 || p.added != 0 {
			t.Fatal("invalid reached native")
		}
	}
}

func TestTrickleIsBoundToPairedPhoneAndRevocation(t *testing.T) {
	p := &tricklePeer{local: trickleDescription}
	p.status.State = "connected"
	authority := &recoveryAuthority{}
	h, err := NewPairedHost(authority, func(time.Time, OfferOptions) (Resources, error) { return Resources{Peer: p}, nil })
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { h.Close("test") })
	w := trickleCall(h, "phone", "/offer", "", `{"version":3}`)
	var offer struct{ Session string }
	if w.Code != 200 || json.Unmarshal(w.Body.Bytes(), &offer) != nil {
		t.Fatal("paired offer", w.Code)
	}
	answer, _ := json.Marshal(map[string]any{"version": 3, "sdp": phoneDescription})
	if trickleCall(h, "phone", "/answer", offer.Session, string(answer)).Code != 200 {
		t.Fatal("answer")
	}
	if trickleCall(h, "other", "/status", offer.Session, iceStatus()).Code != 403 || p.added != 0 {
		t.Fatal("other phone")
	}
	authority.revoked.Store(true)
	h.Revoke("phone")
	if trickleCall(h, "phone", "/status", offer.Session, iceStatus()).Code != 403 || p.added != 0 {
		t.Fatal("revocation")
	}
}
