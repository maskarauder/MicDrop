package session

import (
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"strconv"
	"strings"
	"testing"
	"time"

	"github.com/maskarauder/MicDrop/internal/rtc"
)

func timedOffer(handler http.Handler, token string, recovery, setup int) *httptest.ResponseRecorder {
	r := httptest.NewRequest("POST", "https://192.168.1.2/offer", strings.NewReader(`{"version":3}`))
	r.Header.Set("X-Test-Verified-Identity", "phone")
	if token != "" {
		r.Header.Set("Authorization", "Bearer "+token)
	}
	r.Header.Set(recoveryWindowHeader, strconv.Itoa(recovery))
	r.Header.Set(setupWindowHeader, strconv.Itoa(setup))
	w := httptest.NewRecorder()
	handler.ServeHTTP(w, r)
	return w
}

func timedSession(t *testing.T) (*Server, *restartPeer, *time.Time, string) {
	t.Helper()
	now := time.Now()
	p := &restartPeer{fakePeer: fakePeer{status: rtc.Status{State: "connected"}}}
	s := New(p, reusableToken, now)
	s.version = 3
	s.now = func() time.Time { return now }
	w := timedOffer(s, reusableToken, 90000, 90000)
	var reply struct {
		Session   string
		Version   int `json:"connection_timeouts_version"`
		Recovery  int `json:"recovery_window_ms"`
		Setup     int `json:"setup_window_ms"`
		Heartbeat int `json:"heartbeat_timeout_ms"`
	}
	if w.Code != 200 || json.Unmarshal(w.Body.Bytes(), &reply) != nil || reply.Version != 1 ||
		reply.Recovery != 90000 || reply.Setup != 90000 || reply.Heartbeat != 95000 {
		t.Fatalf("deadlines not acknowledged: %d %s", w.Code, w.Body.String())
	}
	return s, p, &now, reply.Session
}

func TestConnectionTimeoutsValidatedBeforeHostAllocatesResources(t *testing.T) {
	calls := 0
	h, err := NewPairedHost(microphoneAuthority{}, func(time.Time, OfferOptions) (Resources, error) {
		calls++
		return Resources{Peer: &restartPeer{}}, nil
	})
	if err != nil {
		t.Fatal(err)
	}
	defer h.Close("test")
	for _, values := range [][2]int{{0, 45000}, {4999, 45000}, {300001, 45000}, {30000, 9999}, {30000, 120001}} {
		if w := timedOffer(h, "", values[0], values[1]); w.Code != 400 || calls != 0 {
			t.Fatal("invalid settings allocated a peer")
		}
	}
	for _, value := range []string{"", "1e5", "NaN", "-90000", "+90000", "90000,90000"} {
		r := httptest.NewRequest("POST", "/offer", nil)
		r.Header[http.CanonicalHeaderKey(recoveryWindowHeader)] = []string{value}
		if _, ok := readConnectionTimeouts(r, 3); ok {
			t.Fatalf("accepted %q", value)
		}
	}
	r := httptest.NewRequest("POST", "/offer", nil)
	r.Header.Add(recoveryWindowHeader, "90000")
	r.Header.Add(recoveryWindowHeader, "90000")
	if _, ok := readConnectionTimeouts(r, 3); ok {
		t.Fatal("duplicate header accepted")
	}
	if w := timedOffer(h, "", 300000, 120000); w.Code != 200 || calls != 1 {
		t.Fatal("bounded settings rejected")
	}
	if h.active.server.recoveryLimit() != 300*time.Second || h.active.server.setupLimit() != 120*time.Second {
		t.Fatal("host discarded headers")
	}
}

func TestCustomMediaDeadlineSurvivesThirtySecondsAndCannotBeReset(t *testing.T) {
	s, p, now, token := timedSession(t)
	if call(s, "/answer", token, `{"version":3,"sdp":"answer"}`).Code != 200 {
		t.Fatal("answer")
	}
	p.status.State = "disconnected"
	if _, err := s.Check(); err != nil {
		t.Fatal(err)
	}
	failed := *now
	*now = failed.Add(40 * time.Second)
	if call(s, "/status", token, "").Code != 200 {
		t.Fatal("old 30/35-second deadline remained")
	}
	if call(s, "/recover-offer", token, firstRestart).Code != 200 {
		t.Fatal("restart")
	}
	*now = failed.Add(89 * time.Second)
	if call(s, "/status", token, "").Code != 200 {
		t.Fatal("ended before custom deadline")
	}
	*now = failed.Add(90 * time.Second)
	if call(s, "/recover-offer", token, firstRestart).Code != 410 || s.EndReason() != "audio_session_lost" {
		t.Fatal("restart reset deadline")
	}
}

func TestCustomHeartbeatExpiresOnWatchdogAndLateRequest(t *testing.T) {
	for _, watchdog := range []bool{false, true} {
		s, _, now, token := timedSession(t)
		call(s, "/answer", token, `{"version":3,"sdp":"answer"}`)
		*now = now.Add(94 * time.Second)
		if _, err := s.Check(); err != nil {
			t.Fatal("custom heartbeat ended early")
		}
		*now = now.Add(2 * time.Second)
		if watchdog {
			_, _ = s.Check()
		} else if call(s, "/status", token, "").Code != 410 {
			t.Fatal("late heartbeat revived session")
		}
		if s.EndReason() != "receiver_timeout" {
			t.Fatal("missing heartbeat did not expire")
		}
	}
}

func TestCustomSetupDeadlineAndImmediateStop(t *testing.T) {
	s, _, now, token := timedSession(t)
	*now = now.Add(60 * time.Second)
	if call(s, "/answer", token, `{"version":3,"sdp":"answer"}`).Code != 200 {
		t.Fatal("old setup limit remained")
	}
	if call(s, "/stop", token, `{}`).Code != 200 || !s.stopped {
		t.Fatal("custom timeout delayed Stop")
	}
	for _, watchdog := range []bool{false, true} {
		s, _, now, token = timedSession(t)
		*now = now.Add(91 * time.Second)
		if watchdog {
			_, _ = s.Check()
		} else if call(s, "/answer", token, `{"version":3,"sdp":"answer"}`).Code != 410 {
			t.Fatal("late answer accepted")
		}
		if s.EndReason() != "pairing_timeout" {
			t.Fatal("custom setup did not expire")
		}
	}
}

func TestDefaultAndOlderPeerLimitsArePreserved(t *testing.T) {
	s, _, _, _ := recoverySession(t, false)
	if s.recoveryLimit() != 30*time.Second || s.heartbeatLimit() != 35*time.Second || s.setupLimit() != 45*time.Second {
		t.Fatal("defaults changed")
	}
	s.peer = &fakePeer{}
	if s.recoveryLimit() != 10*time.Second || s.heartbeatLimit() != 15*time.Second {
		t.Fatal("old peer defaults changed")
	}
	s.timeouts.recovery = 5 * time.Second
	if s.recoveryLimit() != 5*time.Second {
		t.Fatal("shorter configured window ignored")
	}
}
