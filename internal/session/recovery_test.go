package session

import (
	"encoding/json"
	"errors"
	"net/http"
	"strings"
	"sync/atomic"
	"testing"
	"time"

	"github.com/maskarauder/MicDrop/internal/rtc"
)

type restartPeer struct {
	fakePeer
	restarts    int
	controls    []bool
	failRestart bool
}

type recoveryAuthority struct {
	microphoneAuthority
	revoked atomic.Bool
}

func (a *recoveryAuthority) Allowed(client string) bool {
	return client != "phone" || !a.revoked.Load()
}
func (a *recoveryAuthority) Client(r *http.Request) (string, bool) {
	client, ok := a.microphoneAuthority.Client(r)
	return client, ok && a.Allowed(client)
}

func (p *restartPeer) RestartOffer() (string, error) {
	p.restarts++
	if p.failRestart {
		return "", errors.New("synthetic restart failure")
	}
	return "synthetic restart offer", nil
}
func (p *restartPeer) SetMicrophoneMuted(muted bool) error {
	p.controls = append(p.controls, muted)
	p.status.MicrophoneMuted = muted
	return nil
}
func recoverySession(t *testing.T, microphone bool) (*Server, *restartPeer, *time.Time, string) {
	t.Helper()
	now := time.Now()
	p := &restartPeer{fakePeer: fakePeer{status: rtc.Status{State: "connected"}}}
	s := New(p, strings.Repeat("a", 43), now)
	s.version = 3
	s.microphone = microphone
	s.now = func() time.Time { return now }
	body := `{"version":3}`
	if microphone {
		body = `{"version":3,"microphone_return_version":1}`
	}
	w := call(s, "/offer", s.invitation, body)
	var reply struct {
		Session  string
		Recovery int `json:"ice_restart_version"`
	}
	if w.Code != 200 || json.Unmarshal(w.Body.Bytes(), &reply) != nil || reply.Recovery != 1 {
		t.Fatal("recovery offer capability")
	}
	if call(s, "/answer", reply.Session, `{"version":3,"sdp":"synthetic answer"}`).Code != 200 {
		t.Fatal("initial answer")
	}
	return s, p, &now, reply.Session
}

const firstRestart = `{"version":3,"generation":1}`
const restartAnswer = `{"version":3,"generation":1,"sdp":"synthetic new answer"}`

func TestIceRestartRetriesReusePeerOfferAndAnswer(t *testing.T) {
	s, p, _, token := recoverySession(t, true)
	for i := 0; i < 3; i++ {
		if call(s, "/recover-offer", token, firstRestart).Code != 200 {
			t.Fatal("lost-offer retry")
		}
	}
	if p.restarts != 1 || p.offers != 1 || len(p.controls) != 1 || !p.controls[0] {
		t.Fatal("retry recreated offer or opened mic")
	}
	if call(s, "/microphone", token, `{"version":3,"muted":false}`).Code != 409 {
		t.Fatal("pending restart unmuted cable")
	}
	for i := 0; i < 3; i++ {
		if call(s, "/recover-answer", token, restartAnswer).Code != 200 {
			t.Fatal("lost-answer retry")
		}
	}
	if p.answers != 2 || !p.status.MicrophoneMuted {
		t.Fatal("answer replay reauthorized microphone")
	}
	if call(s, "/recover-answer", token, `{"version":3,"generation":1,"sdp":"changed"}`).Code != 409 {
		t.Fatal("conflicting replay accepted")
	}
	if call(s, "/microphone", token, `{"version":3,"muted":false}`).Code != 200 {
		t.Fatal("verified client control could not unmute")
	}
}
func TestRecoveryCannotBypassAuthenticationOrGenerationBounds(t *testing.T) {
	s, p, _, token := recoverySession(t, false)
	if call(s, "/recover-offer", strings.Repeat("x", 43), firstRestart).Code != 401 {
		t.Fatal("unauthorized recovery")
	}
	for _, body := range []string{`{"version":2,"generation":1}`, `{"version":3,"generation":0}`, `{"version":3,"generation":1000001}`,
		`{"version":3,"generation":1,"device":"untrusted"}`, strings.Repeat(" ", 1024) + firstRestart} {
		if call(s, "/recover-offer", token, body).Code != 400 {
			t.Fatal("unbounded/malformed recovery accepted")
		}
	}
	if call(s, "/recover-offer", token, `{"version":3,"generation":2}`).Code != 409 || p.restarts != 0 {
		t.Fatal("skipped generation")
	}
	if call(s, "/recover-offer", token, firstRestart).Code != 200 ||
		call(s, "/recover-offer", token, `{"version":3,"generation":2}`).Code != 409 || p.restarts != 1 {
		t.Fatal("overlapping restart")
	}
}
func TestRecoveryDeadlineCannotBeRevivedByCachedOfferOrLateAnswer(t *testing.T) {
	for _, answer := range []bool{false, true} {
		s, p, now, token := recoverySession(t, false)
		p.status.State = "disconnected"
		if _, err := s.Check(); err != nil {
			t.Fatal(err)
		}
		*now = now.Add(2 * time.Second)
		if call(s, "/recover-offer", token, firstRestart).Code != 200 {
			t.Fatal("restart")
		}
		*now = now.Add(28 * time.Second)
		p.status.State = "connected"
		path, body := "/recover-offer", firstRestart
		if answer {
			path, body = "/recover-answer", restartAnswer
		}
		if call(s, path, token, body).Code != 410 || s.EndReason() != "audio_session_lost" {
			t.Fatal("late operation revived deadline")
		}
	}
}
func TestPairedFailedMediaHasBoundedRecoveryAndVanishedReceiverStillExpires(t *testing.T) {
	s, p, now, token := recoverySession(t, false)
	p.status.State = "failed"
	if call(s, "/status", token, "").Code != 200 {
		t.Fatal("recoverable failure ended immediately")
	}
	*now = now.Add(29 * time.Second)
	if call(s, "/status", token, "").Code != 200 {
		t.Fatal("recovery window")
	}
	*now = now.Add(time.Second)
	if _, err := s.Check(); err == nil || s.EndReason() != "audio_session_lost" {
		t.Fatal("unbounded media recovery")
	}
	s, _, now, _ = recoverySession(t, false)
	*now = now.Add(36 * time.Second)
	if _, err := s.Check(); err == nil || s.EndReason() != "receiver_timeout" {
		t.Fatal("abandoned capture survived watchdog")
	}
}
func TestStopWinsOverPendingRestart(t *testing.T) {
	s, p, _, token := recoverySession(t, true)
	if call(s, "/recover-offer", token, firstRestart).Code != 200 {
		t.Fatal("restart")
	}
	if call(s, "/stop", token, `{"reason":"user_stop"}`).Code != 200 {
		t.Fatal("Stop")
	}
	if call(s, "/recover-answer", token, restartAnswer).Code != 410 || p.answers != 1 || s.EndReason() != "receiver_stop" {
		t.Fatal("late answer undid Stop")
	}
}
func TestRestartFailureStopsTheSessionWithoutOpeningAnotherPeer(t *testing.T) {
	s, p, _, token := recoverySession(t, true)
	p.failRestart = true
	if call(s, "/recover-offer", token, firstRestart).Code != 500 || s.EndReason() != "audio_session_lost" || p.offers != 1 || !p.status.MicrophoneMuted {
		t.Fatal("failed restart continued or opened capture")
	}
}

func TestRestartRequiresTheActivePairedPhoneAndRevocationEndsIt(t *testing.T) {
	p := &restartPeer{fakePeer: fakePeer{status: rtc.Status{State: "connected"}}}
	authority := &recoveryAuthority{}
	h, err := NewPairedHost(authority, func(time.Time, OfferOptions) (Resources, error) { return Resources{Peer: p}, nil })
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { h.Close("test") })
	w := microphoneCall(h, "phone", "/offer", "", `{"version":3}`)
	var reply struct{ Session string }
	if w.Code != 200 || json.Unmarshal(w.Body.Bytes(), &reply) != nil {
		t.Fatal("claim")
	}
	if microphoneCall(h, "phone", "/answer", reply.Session, `{"version":3,"sdp":"synthetic answer"}`).Code != 200 {
		t.Fatal("answer")
	}
	if microphoneCall(h, "other", "/recover-offer", reply.Session, firstRestart).Code != 403 || p.restarts != 0 {
		t.Fatal("other phone stole recovery")
	}
	if microphoneCall(h, "phone", "/recover-offer", reply.Session, firstRestart).Code != 200 {
		t.Fatal("owner recovery")
	}
	authority.revoked.Store(true)
	h.Revoke("phone")
	if microphoneCall(h, "phone", "/recover-answer", reply.Session, restartAnswer).Code != 403 || p.answers != 1 {
		t.Fatal("revocation allowed late answer")
	}
}
func TestLegacySessionsCannotNegotiateIceRecovery(t *testing.T) {
	p := &restartPeer{}
	s := New(p, strings.Repeat("a", 43), time.Now())
	token := claim(t, s, s.invitation)
	if call(s, "/answer", token, `{"version":1,"sdp":"synthetic answer"}`).Code != 200 {
		t.Fatal("answer")
	}
	if s.recoveryVersion() != 0 || s.heartbeatLimit() != 15*time.Second ||
		call(s, "/recover-offer", token, firstRestart).Code != 409 || p.restarts != 0 {
		t.Fatal("legacy path changed")
	}
}
