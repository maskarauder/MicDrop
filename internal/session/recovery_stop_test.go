package session

import (
	"encoding/json"
	"net/http/httptest"
	"strings"
	"sync/atomic"
	"testing"
	"time"

	"github.com/maskarauder/MicDrop/internal/rtc"
)

type closingContinuousPeer struct {
	continuousPeer
	closing, release chan struct{}
	closes           atomic.Int32
}

func (p *closingContinuousPeer) Close() {
	p.closes.Add(1)
	close(p.closing)
	<-p.release
}

func TestLostStopDuringContinuousRecoveryCanBeRetriedWithoutStoppingSuccessor(t *testing.T) {
	p := &closingContinuousPeer{closing: make(chan struct{}), release: make(chan struct{})}
	p.enabled = true
	p.local = trickleDescription
	p.status.State = "connected"
	calls := 0
	factory := func(time.Time, OfferOptions) (Resources, error) {
		calls++
		if calls == 1 {
			return Resources{Peer: p}, nil
		}
		next := &continuousPeer{enabled: true}
		next.local = trickleDescription
		next.status.State = "connected"
		return Resources{Peer: next}, nil
	}
	h, err := NewPairedHost(microphoneAuthority{}, factory)
	if err != nil {
		t.Fatal(err)
	}
	h.EnableDuplex(factory)
	t.Cleanup(func() { h.Close("test") })
	// Unblock native cleanup even if an assertion fails.
	released := false
	defer func() {
		if !released {
			close(p.release)
		}
	}()
	offer := func(nonce string) *httptest.ResponseRecorder {
		r := httptest.NewRequest("POST", "https://paired.test/offer",
			strings.NewReader(`{"version":3,"microphone_return_version":1,"duplex_version":1}`))
		r.Header.Set("X-Test-Verified-Identity", "phone")
		r.Header.Set(offerAttemptHeader, nonce)
		r.Header.Set("X-MicDrop-Trickle-ICE", "1")
		r.Header.Set(rtc.ContinuousHeader, "1")
		w := httptest.NewRecorder()
		h.ServeHTTP(w, r)
		return w
	}
	w := offer(attemptNonce(1))
	var reply struct{ Session string }
	if w.Code != 200 || json.Unmarshal(w.Body.Bytes(), &reply) != nil || reply.Session == "" {
		t.Fatal("initial offer", w.Code)
	}
	old := activeAttempt(h)
	answer, _ := json.Marshal(map[string]any{"version": 3, "sdp": phoneDescription})
	if microphoneCall(h, "phone", "/answer", reply.Session, string(answer)).Code != 200 ||
		microphoneCall(h, "phone", "/recover-offer", reply.Session, firstRestart).Code != 200 {
		t.Fatal("recovery")
	}
	// Stop was lost in the network change. A reconnect is busy; cancelling
	// that rejected attempt cannot cancel the preceding established session.
	if offer(attemptNonce(2)).Code != 423 ||
		attemptCall(h, "phone", "/cancel-offer", attemptNonce(2), `{"version":3}`).Code != 200 ||
		old.server.EndReason() != "" || p.closes.Load() != 0 {
		t.Fatal("new attempt cancellation reached the recovering session")
	}
	if microphoneCall(h, "other", "/stop", reply.Session, `{"reason":"user_stop"}`).Code != 403 {
		t.Fatal("another phone retried Stop")
	}
	// Replay the original session credential, then retain the busy reservation
	// until native teardown is done. No second peer may share the audio devices.
	if microphoneCall(h, "phone", "/stop", reply.Session, `{"reason":"user_stop"}`).Code != 200 {
		t.Fatal("old Stop retry")
	}
	select {
	case <-p.closing:
	case <-time.After(3 * time.Second):
		t.Fatal("native release did not begin")
	}
	if offer(attemptNonce(3)).Code != 423 || calls != 1 || old.server.EndReason() != "receiver_stop" {
		t.Fatal("new peer allocated before cleanup")
	}
	if microphoneCall(h, "phone", "/recover-answer", reply.Session, restartAnswer).Code != 410 || p.answers != 1 {
		t.Fatal("late recovery answer reopened stopped session")
	}
	close(p.release)
	released = true
	waitSession(t, old)
	if p.closes.Load() != 1 || offer(attemptNonce(3)).Code != 200 || calls != 2 {
		t.Fatal("fresh Connect did not follow native release")
	}
	next := activeAttempt(h)
	if microphoneCall(h, "phone", "/stop", reply.Session, `{"reason":"user_stop"}`).Code != 401 ||
		next.server.EndReason() != "" || p.closes.Load() != 1 {
		t.Fatal("delayed Stop affected successor")
	}
}
