package session

import (
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"reflect"
	"strings"
	"testing"
	"time"

	"github.com/maskarauder/MicDrop/internal/rtc"
)

type signalingPeer struct {
	restartPeer
	routes []bool
}

func (p *signalingPeer) SetLocalSignaling(local bool) { p.routes = append(p.routes, local) }

func routeCall(handler http.Handler, client, path, token, nonce, body string) *httptest.ResponseRecorder {
	r := httptest.NewRequest("POST", "https://paired.test"+path, strings.NewReader(body))
	r.Header.Set("X-Test-Verified-Identity", client)
	r.Header.Set("X-MicDrop-Local-Signaling", "1") // Untrusted headers cannot select local ICE.
	if token != "" {
		r.Header.Set("Authorization", "Bearer "+token)
	}
	if nonce != "" {
		r.Header.Set(offerAttemptHeader, nonce)
	}
	w := httptest.NewRecorder()
	handler.ServeHTTP(w, r)
	return w
}

func TestListenersShareSessionOwnershipAndChooseICEOnlyForNewOffers(t *testing.T) {
	p := &signalingPeer{restartPeer: restartPeer{fakePeer: fakePeer{status: rtc.Status{State: "connected"}}}}
	created := 0
	h, err := NewPairedHost(microphoneAuthority{}, func(time.Time, OfferOptions) (Resources, error) {
		created++
		return Resources{Peer: p}, nil
	})
	if err != nil {
		t.Fatal(err)
	}
	defer h.Close("test")
	lan := LocalSignaling(h)
	if routeCall(lan, "unknown", "/offer", "", "", `{"version":3}`).Code != 403 || created != 0 {
		t.Fatal("LAN bypassed pairing")
	}
	offer := routeCall(h, "phone", "/offer", "", "", `{"version":3}`)
	var reply struct{ Session string }
	if offer.Code != 200 || json.Unmarshal(offer.Body.Bytes(), &reply) != nil {
		t.Fatal("remote offer")
	}
	if !reflect.DeepEqual(p.routes, []bool{false}) {
		t.Fatal("header spoofed local ICE")
	}
	if routeCall(lan, "phone", "/offer", "", "", `{"version":3}`).Code != 423 || created != 1 {
		t.Fatal("second listener allocated another session")
	}
	if routeCall(lan, "other", "/answer", reply.Session, "", `{"version":3,"sdp":"answer"}`).Code != 403 ||
		routeCall(lan, "phone", "/answer", reply.Session, "", `{"version":3,"sdp":"answer"}`).Code != 200 {
		t.Fatal("cross-listener owner binding")
	}
	if routeCall(lan, "phone", "/recover-offer", "wrong", "", firstRestart).Code != 401 || len(p.routes) != 1 {
		t.Fatal("unauthenticated request changed ICE policy")
	}
	if routeCall(lan, "phone", "/recover-offer", reply.Session, "", firstRestart).Code != 200 ||
		routeCall(h, "phone", "/recover-offer", reply.Session, "", firstRestart).Code != 200 ||
		!reflect.DeepEqual(p.routes, []bool{false, true}) || p.restarts != 1 {
		t.Fatal("generation replay changed routes or recreated offer")
	}
	current := activeAttempt(h)
	if routeCall(h, "phone", "/recover-answer", reply.Session, "", restartAnswer).Code != 200 ||
		routeCall(lan, "phone", "/stop", reply.Session, "", `{"reason":"user_stop"}`).Code != 200 {
		t.Fatal("cross-listener recovery/stop failed")
	}
	waitSession(t, current)
	if activeAttempt(h) != nil {
		t.Fatal("session slot retained after cleanup")
	}
}

func TestLostLANOfferMustBeCancelledBeforeFreshRendezvousOffer(t *testing.T) {
	created := 0
	h, err := NewPairedHost(microphoneAuthority{}, func(time.Time, OfferOptions) (Resources, error) {
		created++
		return Resources{Peer: &cyclePeer{}}, nil
	})
	if err != nil {
		t.Fatal(err)
	}
	defer h.Close("test")
	lan := LocalSignaling(h)
	old, next := attemptNonce(1), attemptNonce(2)
	if routeCall(lan, "phone", "/offer", "", old, `{"version":3}`).Code != 200 {
		t.Fatal("offer")
	}
	if routeCall(h, "phone", "/offer", "", next, `{"version":3}`).Code != 423 || created != 1 {
		t.Fatal("ambiguous offer duplicated")
	}
	if routeCall(h, "other", "/cancel-offer", "", old, `{"version":3}`).Code != 200 || activeAttempt(h) == nil {
		t.Fatal("another paired phone cancelled the owner")
	}
	previous := activeAttempt(h)
	if routeCall(h, "phone", "/cancel-offer", "", old, `{"version":3}`).Code != 200 {
		t.Fatal("cancel")
	}
	waitSession(t, previous)
	if routeCall(h, "phone", "/offer", "", next, `{"version":3}`).Code != 200 || created != 2 {
		t.Fatal("fresh rendezvous offer")
	}
	if routeCall(lan, "phone", "/offer", "", old, `{"version":3}`).Code != 410 || created != 2 {
		t.Fatal("delayed old offer survived")
	}
	current := activeAttempt(h)
	if routeCall(lan, "phone", "/cancel-offer", "", old, `{"version":3}`).Code != 200 || activeAttempt(h) != current {
		t.Fatal("stale cancellation stopped successor")
	}
}
