package session

import (
	"encoding/base64"
	"encoding/json"
	"fmt"
	"net/http/httptest"
	"strings"
	"testing"
	"time"

	"github.com/maskarauder/MicDrop/internal/rtc"
)

func attemptNonce(n byte) string {
	return base64.RawURLEncoding.EncodeToString([]byte(strings.Repeat(string([]byte{n}), 32)))
}

func attemptCall(h *Host, client, path, nonce, body string) *httptest.ResponseRecorder {
	r := httptest.NewRequest("POST", "https://192.168.1.2"+path, strings.NewReader(body))
	if h.authority == nil {
		r.Header.Set("Authorization", "Bearer "+reusableToken)
	} else {
		r.Header.Set("X-Test-Verified-Identity", client)
	}
	if nonce != "" {
		r.Header.Set(offerAttemptHeader, nonce)
	}
	w := httptest.NewRecorder()
	h.ServeHTTP(w, r)
	return w
}

func activeAttempt(h *Host) *managedSession {
	h.mu.Lock()
	defer h.mu.Unlock()
	return h.active
}

func TestOfferCancellationBeforeOfferIsScopedAndAllowsFreshConnect(t *testing.T) {
	for _, paired := range []bool{false, true} {
		t.Run(fmt.Sprint(paired), func(t *testing.T) {
			calls := 0
			factory := func(time.Time, OfferOptions) (Resources, error) { calls++; return Resources{Peer: &cyclePeer{}}, nil }
			h := NewHost(reusableToken, time.Now().Add(time.Hour), factory)
			version := 2
			if paired {
				h.authority = microphoneAuthority{}
				version = 3
			}
			defer h.Close("test")
			body := fmt.Sprintf(`{"version":%d}`, version)
			nonce := attemptNonce(1)
			if w := attemptCall(h, "phone", "/cancel-offer", nonce, body); w.Code != 200 || !strings.Contains(w.Body.String(), `"offer_cancelled":true`) {
				t.Fatalf("cancel: %d %s", w.Code, w.Body.String())
			}
			if attemptCall(h, "phone", "/offer", nonce, body).Code != 410 || calls != 0 || activeAttempt(h) != nil {
				t.Fatal("late offer allocated resources after Stop")
			}
			if attemptCall(h, "phone", "/offer", attemptNonce(2), body).Code != 200 || calls != 1 {
				t.Fatal("cancellation blocked a new connection")
			}
		})
	}
}

func TestLostOfferCanBeCancelledWithoutSessionTokenAndCannotStopSuccessor(t *testing.T) {
	h, err := NewPairedHost(microphoneAuthority{}, func(time.Time, OfferOptions) (Resources, error) {
		return Resources{Peer: &cyclePeer{}}, nil
	})
	if err != nil {
		t.Fatal(err)
	}
	defer h.Close("test")
	first, second := attemptNonce(1), attemptNonce(2)
	offer := attemptCall(h, "phone", "/offer", first, `{"version":3}`)
	if offer.Code != 200 {
		t.Fatal("offer")
	}
	old := activeAttempt(h)
	var response struct{ Session string }
	if err := json.Unmarshal(offer.Body.Bytes(), &response); err != nil {
		t.Fatal(err)
	}
	for _, client := range []string{"unknown", "other"} {
		w := attemptCall(h, client, "/cancel-offer", first, `{"version":3}`)
		if client == "unknown" && w.Code != 403 {
			t.Fatal("unpaired cancellation accepted")
		}
		if old.cancelled || old.server.EndReason() != "" {
			t.Fatal("another identity cancelled the offer")
		}
	}
	if attemptCall(h, "phone", "/cancel-offer", second, `{"version":3}`).Code != 200 || old.cancelled {
		t.Fatal("different nonce cancelled the offer")
	}
	if attemptCall(h, "phone", "/cancel-offer", first, `{"version":3}`).Code != 200 {
		t.Fatal("cancel lost response")
	}
	waitSession(t, old)
	if old.server.EndReason() != "offer_cancelled" || old.resources.Peer.(*cyclePeer).closes.Load() != 1 {
		t.Fatal("cancel did not finalize exactly once")
	}
	if attemptCall(h, "phone", "/offer", first, `{"version":3}`).Code != 410 {
		t.Fatal("cancelled offer replay")
	}
	// The second nonce was already cancelled above; a real reconnect creates a fresh one.
	if attemptCall(h, "phone", "/offer", attemptNonce(3), `{"version":3}`).Code != 200 {
		t.Fatal("fresh reconnect")
	}
	next := activeAttempt(h)
	for i := 0; i < 2; i++ {
		if attemptCall(h, "phone", "/cancel-offer", first, `{"version":3}`).Code != 200 || next.cancelled || next.server.EndReason() != "" {
			t.Fatal("delayed cancellation stopped successor")
		}
	}
	if microphoneCall(h, "phone", "/answer", response.Session, `{"version":3,"sdp":"stale"}`).Code != 401 {
		t.Fatal("stale answer reached successor")
	}
}

type blockedOfferPeer struct {
	cyclePeer
	entered, releaseOffer chan struct{}
}

func (p *blockedOfferPeer) Offer() (string, error) {
	close(p.entered)
	<-p.releaseOffer
	return p.cyclePeer.Offer()
}

func TestOfferCancellationDuringFactoryOrNativeOfferSerializesCleanup(t *testing.T) {
	for _, phase := range []string{"factory", "native_offer"} {
		t.Run(phase, func(t *testing.T) {
			entered, release := make(chan struct{}), make(chan struct{})
			p := &blockedOfferPeer{entered: entered, releaseOffer: release}
			h, err := NewPairedHost(microphoneAuthority{}, func(time.Time, OfferOptions) (Resources, error) {
				if phase == "factory" {
					close(entered)
					<-release
					return Resources{Peer: &p.cyclePeer}, nil
				}
				return Resources{Peer: p}, nil
			})
			if err != nil {
				t.Fatal(err)
			}
			defer h.Close("test")
			released := false
			defer func() {
				if !released {
					close(release)
				}
			}()
			done := make(chan *httptest.ResponseRecorder, 1)
			go func() { done <- attemptCall(h, "phone", "/offer", attemptNonce(4), `{"version":3}`) }()
			select {
			case <-entered:
			case <-time.After(3 * time.Second):
				t.Fatal("setup did not start")
			}
			current := activeAttempt(h)
			if w := attemptCall(h, "phone", "/cancel-offer", attemptNonce(4), `{"version":3}`); w.Code != 200 {
				t.Fatal("Stop waited for native work")
			}
			if p.closes.Load() != 0 {
				t.Fatal("native peer closed during setup")
			}
			if attemptCall(h, "phone", "/offer", attemptNonce(5), `{"version":3}`).Code != 423 {
				t.Fatal("session slot released before native teardown")
			}
			close(release)
			released = true
			select {
			case <-done:
			case <-time.After(3 * time.Second):
				t.Fatal("offer did not finish")
			}
			waitSession(t, current)
			if p.closes.Load() != 1 || current.server.EndReason() != "offer_cancelled" {
				t.Fatal("cancelled setup was left for the answer watchdog")
			}
		})
	}
}

func TestOfferCancellationRejectsBadAuthenticationAndMalformedRequests(t *testing.T) {
	calls := 0
	h := NewHost(reusableToken, time.Now().Add(time.Hour), func(time.Time, OfferOptions) (Resources, error) {
		calls++
		return Resources{Peer: &cyclePeer{fakePeer: fakePeer{status: rtc.Status{State: "connected"}}}}, nil
	})
	defer h.Close("test")
	nonce := attemptNonce(6)
	if hostCall(h, "POST", "/cancel-offer", strings.Repeat("b", 43), `{"version":2}`).Code != 401 {
		t.Fatal("invitation not checked")
	}
	for _, bad := range []string{"", "short", strings.Repeat("/", 43), strings.Repeat("a", 43) + "=", strings.Repeat("a", 43)} {
		if attemptCall(h, "", "/cancel-offer", bad, `{"version":2}`).Code != 400 {
			t.Fatalf("bad nonce accepted: %q", bad)
		}
	}
	for _, body := range []string{`{"version":3}`, `{"version":2,"other":true}`, `{"version":2} {}`, strings.Repeat(" ", 1024) + `{"version":2}`} {
		if attemptCall(h, "", "/cancel-offer", nonce, body).Code != 400 {
			t.Fatal("bad cancellation body")
		}
	}
	r := httptest.NewRequest("POST", "https://192.168.1.2/offer", strings.NewReader(`{"version":2}`))
	r.Header.Set("Authorization", "Bearer "+reusableToken)
	r.Header.Add(offerAttemptHeader, nonce)
	r.Header.Add(offerAttemptHeader, nonce)
	w := httptest.NewRecorder()
	h.ServeHTTP(w, r)
	if w.Code != 400 || calls != 0 || len(h.cancelledOffers) != 0 {
		t.Fatal("malformed attempt allocated resources")
	}
}

func TestOfferCancellationCacheIsBoundedExpiresAndRetriesAreIdempotent(t *testing.T) {
	now := time.Now()
	h := NewHost(reusableToken, now.Add(time.Hour), func(time.Time, OfferOptions) (Resources, error) {
		t.Fatal("unexpected allocation")
		return Resources{}, nil
	})
	h.now = func() time.Time { return now }
	h.cancelledOffers = make(map[offerAttempt]time.Time)
	for i := 0; i < maxCancelledOffers; i++ {
		h.cancelledOffers[offerAttempt{"", attemptNonce(byte(i))}] = now.Add(cancelledOfferTTL)
	}
	fresh := base64.RawURLEncoding.EncodeToString([]byte(strings.Repeat("x", 31) + "y"))
	if attemptCall(h, "", "/cancel-offer", fresh, `{"version":2}`).Code != 429 || len(h.cancelledOffers) != maxCancelledOffers {
		t.Fatal("unbounded cancellation cache")
	}
	if attemptCall(h, "", "/cancel-offer", attemptNonce(1), `{"version":2}`).Code != 200 {
		t.Fatal("duplicate cancellation not idempotent")
	}
	now = now.Add(cancelledOfferTTL)
	if attemptCall(h, "", "/cancel-offer", fresh, `{"version":2}`).Code != 200 || len(h.cancelledOffers) != 1 {
		t.Fatal("expired tombstones not reclaimed")
	}
}
