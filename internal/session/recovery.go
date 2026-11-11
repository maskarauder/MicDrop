package session

import (
	"crypto/sha256"
	"net/http"
	"strings"
	"time"

	"github.com/maskarauder/MicDrop/internal/rtc"
)

// Only one bounded offer and answer digest are retained. Lost HTTP replies are
// retried with the same generation, never by creating another peer/offer.
type iceRecovery struct {
	generation  uint64
	offer       string
	answer      [32]byte
	pending     bool
	mediaReady  bool
	lastStarted time.Time
}

func (s *Server) recoveryVersion() int {
	_, available := s.peer.(rtc.RestartPeer)
	if s.version == 3 && available {
		return 1
	}
	return 0
}
func (s *Server) heartbeatLimit() time.Duration {
	return s.recoveryLimit() + 5*time.Second
}
func (s *Server) recoveryStatus(status rtc.Status) rtc.Status {
	status.ICERestarts = s.recovery.generation
	status.RecoveryPending = s.recovery.pending
	if s.continuous != nil {
		status.ContinuousICE = s.continuous.Status()
	}
	if s.trickle != nil {
		status.TrickleICE = &rtc.TrickleStatus{Version: 1, Sent: len(s.trickle.Local), Acknowledged: s.trickle.Ack,
			Received: len(s.trickle.Remote), LocalComplete: s.trickle.LocalComplete, RemoteComplete: s.trickle.RemoteComplete,
			Active: s.trickleVersion() == 1}
	}
	return status
}
func (s *Server) recoverOffer(w http.ResponseWriter, r *http.Request) {
	if !s.answered || s.recoveryVersion() != 1 {
		http.Error(w, "Recovery unavailable", 409)
		return
	}
	if s.recoveryExpired(w) {
		return
	}
	var request struct {
		Version    int    `json:"version"`
		Generation uint64 `json:"generation"`
	}
	if !readJSONLimit(w, r, &request, 1024) || request.Version != 3 || request.Generation == 0 || request.Generation > 1_000_000 {
		http.Error(w, "Invalid recovery request", 400)
		return
	}
	if request.Generation == s.recovery.generation {
		respond(w, map[string]any{"version": 3, "generation": request.Generation, "sdp": s.recovery.offer})
		return
	}
	if request.Generation != s.recovery.generation+1 || s.recovery.pending ||
		(!s.recovery.lastStarted.IsZero() && s.now().Sub(s.recovery.lastStarted) < 5*time.Second) {
		http.Error(w, "Recovery generation unavailable", 409)
		return
	}
	status, err := s.peer.Status()
	if err != nil {
		s.stop("statistics_unavailable")
		http.Error(w, "Statistics unavailable", 500)
		return
	}
	if s.checkMedia(status) != nil {
		http.Error(w, "Audio session ended", 410)
		return
	}
	// The original interruption deadline does not move on a retry/restart.
	if s.disconnectedAt.IsZero() {
		s.disconnectedAt = s.now()
	}
	if s.microphone {
		if err := s.peer.(rtc.MicrophonePeer).SetMicrophoneMuted(true); err != nil {
			s.stop("microphone_bridge_failed")
			http.Error(w, "Cable mute failed", 500)
			return
		}
	}
	selectSignalingRoute(s.peer, r)
	offer, err := s.peer.(rtc.RestartPeer).RestartOffer()
	if err != nil || len(offer) == 0 || len(offer) > 65536 || strings.ContainsRune(offer, 0) {
		s.stop("audio_session_lost")
		http.Error(w, "Recovery offer failed", 500)
		return
	}
	if s.continuous != nil {
		s.continuous = &rtc.ContinuousICE{Generation: request.Generation, RelayOnly: s.continuous.RelayOnly}
		if err := s.continuous.Observe(offer); err != nil {
			s.stop("ice_exchange_failed")
			http.Error(w, "Recovery ICE unavailable", 500)
			return
		}
	}
	s.recovery = iceRecovery{generation: request.Generation, offer: offer, pending: true, lastStarted: s.now()}
	respond(w, map[string]any{"version": 3, "generation": request.Generation, "sdp": offer})
}
func (s *Server) recoverAnswer(w http.ResponseWriter, r *http.Request) {
	if !s.answered || s.recoveryVersion() != 1 {
		http.Error(w, "Recovery unavailable", 409)
		return
	}
	if s.recoveryExpired(w) {
		return
	}
	var request struct {
		Version    int    `json:"version"`
		Generation uint64 `json:"generation"`
		SDP        string `json:"sdp"`
	}
	if !readJSON(w, r, &request) || request.Version != 3 || request.Generation == 0 ||
		request.Generation != s.recovery.generation || len(request.SDP) == 0 || len(request.SDP) > 65536 || strings.ContainsRune(request.SDP, 0) {
		http.Error(w, "Invalid recovery answer", 400)
		return
	}
	digest := sha256.Sum256([]byte(request.SDP))
	if !s.recovery.pending {
		if digest != s.recovery.answer {
			http.Error(w, "Recovery answer unavailable", 409)
			return
		}
		respond(w, map[string]any{"ok": true, "generation": request.Generation})
		return
	}
	if s.continuous != nil {
		if err := s.continuous.SetRemote(request.SDP); err != nil {
			http.Error(w, "Invalid recovery ICE answer", 400)
			return
		}
	}
	if err := s.peer.Answer(request.SDP); err != nil {
		s.stop("answer_rejected")
		http.Error(w, "Recovery answer rejected", 400)
		return
	}
	s.recovery.pending = false
	s.recovery.answer = digest
	s.lastSeen = s.now()
	// The cable stays muted. The phone re-verifies its selected route and applies
	// the latest user mute through the ordinary acknowledged microphone control.
	respond(w, map[string]any{"ok": true, "generation": request.Generation})
}
func (s *Server) recoveryExpired(w http.ResponseWriter) bool {
	if !s.disconnectedAt.IsZero() && s.now().Sub(s.disconnectedAt) >= s.recoveryLimit() {
		s.stop("audio_session_lost")
		http.Error(w, "Recovery expired", 410)
		return true
	}
	return false
}
