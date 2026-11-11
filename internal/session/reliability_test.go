package session

import (
	"encoding/json"
	"strings"
	"testing"
	"time"

	"github.com/maskarauder/MicDrop/internal/rtc"
)

func connected(t *testing.T) (*Server, *fakePeer, *time.Time, string) {
	t.Helper()
	now := time.Now()
	peer := &fakePeer{status: rtc.Status{State: "connected"}}
	invitation := strings.Repeat("a", 43)
	s := New(peer, invitation, now)
	s.now = func() time.Time { return now }
	token := claim(t, s, invitation)
	if call(s, "/answer", token, `{"version":1,"sdp":"answer"}`).Code != 200 {
		t.Fatal("answer")
	}
	return s, peer, &now, token
}

func TestTransientDisconnectRecoversWithoutNewSession(t *testing.T) {
	s, p, now, token := connected(t)
	p.status.State = "disconnected"
	if _, err := s.Check(); err != nil {
		t.Fatal("disconnect ended immediately")
	}
	*now = now.Add(8 * time.Second)
	if call(s, "/status", token, "").Code != 200 {
		t.Fatal("grace heartbeat failed")
	}
	p.status.State = "connected"
	*now = now.Add(time.Second)
	if _, err := s.Check(); err != nil {
		t.Fatal("early recovery failed")
	}
	*now = now.Add(3 * time.Second)
	if call(s, "/status", token, "").Code != 200 || p.offers != 1 || p.answers != 1 {
		t.Fatal("recovery renegotiated or kept old deadline")
	}
}

func TestDisconnectDeadlineCannotBeExtendedOrRevived(t *testing.T) {
	for _, lateConnected := range []bool{false, true} {
		s, p, now, token := connected(t)
		p.status.State = "disconnected"
		if call(s, "/status", token, "").Code != 200 {
			t.Fatal("initial grace poll")
		}
		*now = now.Add(8 * time.Second)
		if call(s, "/status", token, "").Code != 200 {
			t.Fatal("grace poll")
		}
		*now = now.Add(2 * time.Second)
		if lateConnected {
			p.status.State = "connected"
		}
		if call(s, "/status", token, "").Code != 410 || s.EndReason() != "audio_session_lost" {
			t.Fatal("late status revived media deadline")
		}
	}
}

func TestWatchdogStillEndsAfterControlDisappears(t *testing.T) {
	s, _, now, _ := connected(t)
	*now = now.Add(16 * time.Second)
	if _, err := s.Check(); err == nil || s.EndReason() != "receiver_timeout" {
		t.Fatal("watchdog bypassed")
	}
}

func TestStopDuringRecoveryPreservesReceiverReason(t *testing.T) {
	for wire, expected := range map[string]string{"user_stop": "receiver_stop", "focus_loss": "receiver_focus_lost",
		"user_pause": "receiver_pause", "focus_loss_transient": "receiver_focus_lost_transient",
		"focus_loss_permanent": "receiver_focus_lost_permanent",
		"output_lost":          "receiver_output_lost", "service_stopped": "receiver_service_stopped", "connection_failed": "receiver_failure"} {
		s, p, _, token := connected(t)
		p.status.State = "disconnected"
		s.Check()
		if call(s, "/stop", token, `{"reason":"`+wire+`"}`).Code != 200 {
			t.Fatal("stop rejected")
		}
		p.status.State = "closed"
		if _, err := s.Check(); err == nil || s.EndReason() != expected {
			t.Fatalf("stop reason lost: %s", s.EndReason())
		}
	}
}

func TestOfferAdvertisesDetailedLifecycleReasons(t *testing.T) {
	token := strings.Repeat("a", 43)
	s := New(&fakePeer{}, token, time.Now())
	response := call(s, "/offer", token, `{"version":1}`)
	var offer struct {
		LifecycleVersion int `json:"session_lifecycle_version"`
	}
	if response.Code != 200 || json.Unmarshal(response.Body.Bytes(), &offer) != nil || offer.LifecycleVersion != 2 {
		t.Fatalf("missing lifecycle capability: HTTP %d", response.Code)
	}
}

func TestStopReasonIsBoundedAuthenticatedAndAllowlisted(t *testing.T) {
	s, _, _, token := connected(t)
	if call(s, "/stop", strings.Repeat("x", 43), `{"reason":"user_stop"}`).Code != 401 {
		t.Fatal("unauthenticated stop")
	}
	for _, body := range []string{`{"reason":"arbitrary user text"}`, `{"reason":"user_stop","secret":true}`,
		`{"reason":"user_stop"} {}`, strings.Repeat(" ", 1024) + `{}`} {
		if call(s, "/stop", token, body).Code != 400 || s.EndReason() != "" {
			t.Fatal("invalid stop changed session")
		}
	}
	if call(s, "/stop", token, `{}`).Code != 200 || s.EndReason() != "receiver_stop" {
		t.Fatal("legacy stop failed")
	}
}
