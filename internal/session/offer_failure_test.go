package session

import (
	"errors"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"

	"github.com/maskarauder/MicDrop/internal/diagnostics"
	"github.com/maskarauder/MicDrop/internal/rtc"
)

type failedOfferPeer struct {
	cyclePeer
	err error
}

func (p *failedOfferPeer) Offer() (string, error) { return "", p.err }

func TestOfferFailureRetainsGatheringBeforeClosingAndAllowsAnotherSession(t *testing.T) {
	for _, message := range []string{"ICE candidate gathering timed out", "private-url private-token private-sdp"} {
		now := time.Now()
		path := filepath.Join(t.TempDir(), "session.jsonl")
		log, _, err := diagnostics.Create(path, diagnostics.DesktopCapture, now)
		if err != nil {
			t.Fatal(err)
		}
		peer := &failedOfferPeer{err: errors.New(message)}
		peer.status.ICEGathering = &rtc.ICEGathering{Result: "timed_out", ElapsedMS: 15000, RelayOnly: true, MediaSections: 1}
		var current *managedSession
		var h *Host
		attempt := 0
		h = NewHost(reusableToken, now.Add(time.Hour), func(time.Time, OfferOptions) (Resources, error) {
			attempt++
			if attempt > 1 {
				return Resources{Peer: &cyclePeer{}}, nil
			}
			h.mu.Lock()
			current = h.active
			h.mu.Unlock()
			return Resources{Peer: peer, Log: log}, nil
		})
		w := hostCall(h, "POST", "/offer", reusableToken, `{"version":2}`)
		if w.Code != 500 || w.Body.String() != "Offer failed\n" {
			t.Fatal("offer failure did not return the bounded public response")
		}
		waitSession(t, current)
		data, err := os.ReadFile(path)
		if err != nil {
			t.Fatal(err)
		}
		body := string(data)
		failure, status, end := strings.Index(body, `"type":"offer_failure"`), strings.Index(body, `"type":"windows_status"`), strings.Index(body, `"type":"session_end"`)
		if failure < 0 || status <= failure || end <= status || !strings.Contains(body, `"ice_gathering":{"result":"timed_out"`) ||
			!strings.Contains(body, `"reason":"offer_failed"`) || strings.Contains(body, "private-") || peer.closes.Load() != 1 {
			t.Fatalf("missing or unsafe setup diagnostics: %s", body)
		}
		if message == "ICE candidate gathering timed out" && !strings.Contains(body, `"code":"ice_gathering_timeout"`) {
			t.Fatal("underlying gather failure was discarded")
		}
		if hostCall(h, "POST", "/offer", reusableToken, `{"version":2}`).Code != 200 {
			t.Fatal("failed offer left the persistent host busy")
		}
		h.Close("test")
	}
}
