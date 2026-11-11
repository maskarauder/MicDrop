package session

import (
	"encoding/base64"
	"net/http"
	"time"
)

const offerAttemptHeader = "X-MicDrop-Offer-Attempt"

// Keep cancellation ahead of a delayed /offer. Bounded by both the existing
// authenticated request budget and this fixed cap; never evict a live tombstone.
const cancelledOfferTTL = 2 * time.Minute
const maxCancelledOffers = 256

type offerAttempt struct{ client, nonce string }

func readOfferAttempt(r *http.Request, required bool) (string, bool) {
	values := r.Header.Values(offerAttemptHeader)
	if len(values) == 0 {
		return "", !required // Old clients still use the normal session credential.
	}
	if len(values) != 1 || len(values[0]) != 43 {
		return "", false
	}
	decoded, err := base64.RawURLEncoding.DecodeString(values[0])
	return values[0], err == nil && len(decoded) == 32 && base64.RawURLEncoding.EncodeToString(decoded) == values[0]
}

// Host.mu must be held. Nonces are private capabilities, never diagnostics.
func (h *Host) pruneCancelledOffers() {
	for key, expires := range h.cancelledOffers {
		if !h.now().Before(expires) {
			delete(h.cancelledOffers, key)
		}
	}
}

func (h *Host) cancelOffer(w http.ResponseWriter, r *http.Request, client string) {
	version := 2
	if h.authority != nil {
		version = 3
	}
	// Paired identity was verified by ServeHTTP. Legacy listeners still require
	// their invitation, in addition to the unguessable per-attempt nonce.
	if (version == 2 && !equalToken(r.Header.Get("Authorization"), h.invitation)) ||
		(version == 3 && r.Header.Get("Authorization") != "") {
		http.Error(w, "Connection link rejected", 401)
		return
	}
	nonce, ok := readOfferAttempt(r, true)
	var request struct {
		Version int `json:"version"`
	}
	if !ok || !readJSONLimit(w, r, &request, 1024) || request.Version != version {
		http.Error(w, "Invalid connection cancellation", 400)
		return
	}
	h.mu.Lock()
	if h.closed != "" {
		h.mu.Unlock()
		http.Error(w, "Host stopped", 410)
		return
	}
	h.pruneCancelledOffers()
	key := offerAttempt{client, nonce}
	if _, exists := h.cancelledOffers[key]; !exists {
		if len(h.cancelledOffers) >= maxCancelledOffers {
			h.mu.Unlock()
			http.Error(w, "Cancellation limit", 429)
			return
		}
		if h.cancelledOffers == nil {
			h.cancelledOffers = make(map[offerAttempt]time.Time)
		}
		h.cancelledOffers[key] = h.now().Add(cancelledOfferTTL)
	}
	current := h.active
	ready := false
	if current != nil && current.client == client && current.attempt == nonce {
		current.cancelled = true
		ready = current.server != nil
	}
	h.mu.Unlock()
	if ready {
		h.finish(current, "offer_cancelled")
	}
	// A factory still in progress observes cancelled when publishing resources.
	// Close remains serialized with native work; acknowledgment does not release
	// the session slot before teardown completes. A stale nonce cannot stop a successor.
	respond(w, map[string]bool{"offer_cancelled": true})
}
