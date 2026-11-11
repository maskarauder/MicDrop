// Package session implements bounded LAN session control.
// TLS authenticates the host, invitation possession authenticates one receiver,
// and WebRTC owns DTLS-SRTP media transport. No audio goes through HTTP or Go.
package session

import (
	"crypto/sha256"
	"crypto/subtle"
	"encoding/json"
	"errors"
	"io"
	"net/http"
	"strconv"
	"strings"
	"sync"
	"time"

	"github.com/maskarauder/MicDrop/internal/diagnostics"
	"github.com/maskarauder/MicDrop/internal/phonecontrol"
	"github.com/maskarauder/MicDrop/internal/rtc"
)

const MaxBody = 96 * 1024 // Bounded JSON escaping overhead for <=64 KiB SDP.

type offerRequest struct {
	Version          int `json:"version"`
	MicrophoneReturn int `json:"microphone_return_version,omitempty"`
	Duplex           int `json:"duplex_version,omitempty"`
}

func (r offerRequest) valid(version int) bool {
	return r.Version == version && (r.MicrophoneReturn == 0 || (r.MicrophoneReturn == 1 && version == 3)) &&
		(r.Duplex == 0 || (r.Duplex == 1 && r.MicrophoneReturn == 1 && version == 3))
}

type Server struct {
	mu                           sync.Mutex
	peer                         rtc.Peer
	invitation, session          string
	expires, claimedAt, lastSeen time.Time
	claimed, answered, stopped   bool
	limits                       *requestLimits
	version                      int
	now                          func() time.Time
	recorder                     *diagnostics.Log
	lastReport                   uint64
	lastReportDigest             [32]byte
	lastReportLog                string
	disconnectedAt               time.Time
	endReason                    string
	microphone                   bool
	duplex                       bool
	connectionDiagnostics        bool
	recovery                     iceRecovery
	timeouts                     connectionTimeouts
	trickle                      *rtc.ICEExchange
	continuous                   *rtc.ContinuousICE
	phoneControl                 bool
	phoneSettings                phonecontrol.State
	phoneReport                  *diagnostics.AndroidReport
	phoneReportAt                time.Time
}

type Option func(*Server)

func WithDiagnostics(recorder *diagnostics.Log) Option {
	return func(s *Server) { s.recorder = recorder }
}

func New(peer rtc.Peer, invitation string, now time.Time, options ...Option) *Server {
	s := &Server{peer: peer, invitation: invitation, expires: now.Add(5 * time.Minute), limits: newRequestLimits(), version: 1, now: time.Now}
	for _, option := range options {
		option(s)
	}
	return s
}

func equalToken(header, token string) bool {
	return len(token) == 43 && len(header) == 50 && subtle.ConstantTimeCompare([]byte(header), []byte("Bearer "+token)) == 1
}

func (s *Server) ServeHTTP(w http.ResponseWriter, r *http.Request) {
	if !s.limits.enter(w, r, s.now()) {
		return
	}
	defer s.limits.leave()
	s.serve(w, r)
}

// serve runs after the listener's transport and rate checks.
func (s *Server) serve(w http.ResponseWriter, r *http.Request) {
	s.mu.Lock()
	defer s.mu.Unlock()
	if s.stopped {
		http.Error(w, "Session ended", 410)
		return
	}
	// Enforce deadlines on requests too: a late heartbeat must not revive a
	// session during the interval before the host watchdog next runs.
	if s.claimed && ((!s.answered && s.now().Sub(s.claimedAt) > s.setupLimit()) ||
		(s.answered && s.now().Sub(s.lastSeen) > s.heartbeatLimit())) {
		s.stop("receiver_timeout")
		if !s.answered {
			s.endReason = "pairing_timeout"
		}
		http.Error(w, "Session expired", 410)
		return
	}
	if r.URL.Path == "/offer" && r.Method == http.MethodPost {
		if s.claimed || !s.now().Before(s.expires) || !equalToken(r.Header.Get("Authorization"), s.invitation) {
			http.Error(w, "Invitation unavailable", 401)
			return
		}
		var request offerRequest
		if !readJSON(w, r, &request) || !request.valid(s.version) || (request.MicrophoneReturn == 1) != s.microphone || (request.Duplex == 1) != s.duplex {
			http.Error(w, "Invalid protocol version", 400)
			return
		}
		timeouts, valid := readConnectionTimeouts(r, s.version)
		if !valid {
			http.Error(w, "Invalid connection timeouts", 400)
			return
		}
		s.timeouts = timeouts
		phoneControl, valid := readPhoneControl(r, s.version)
		if !valid {
			http.Error(w, "Invalid phone control capability", 400)
			return
		}
		s.phoneControl = phoneControl
		if s.microphone {
			if _, ok := s.peer.(rtc.MicrophonePeer); !ok {
				s.stop("microphone_return_unavailable")
				http.Error(w, "Microphone return unavailable", 409)
				return
			}
		}
		s.claimed = true
		s.claimedAt = s.now()
		secret, err := Secret()
		if err != nil {
			s.stop("session_creation_failed")
			http.Error(w, "Session unavailable", 500)
			return
		}
		s.session = secret
		selectSignalingRoute(s.peer, r)
		var offer string
		if p, ok := s.peer.(rtc.TricklePeer); ok && s.version == 3 && r.Header.Get("X-MicDrop-Trickle-ICE") == "1" {
			offer, err = p.TrickleOffer()
			if err == nil {
				if cp, ok := p.(rtc.ContinuousPeer); ok && cp.ContinuousICE() && r.Header.Get(rtc.ContinuousHeader) == "1" {
					s.continuous = &rtc.ContinuousICE{RelayOnly: cp.ForceRelay()}
					err = s.continuous.Observe(offer)
				} else {
					s.trickle = &rtc.ICEExchange{}
					err = s.trickle.Observe(offer, false)
				}
			}
		} else {
			offer, err = s.peer.Offer()
		}
		if err != nil {
			s.recorder.OfferFailure(err)
			s.stop("offer_failed")
			http.Error(w, "Offer failed", 500)
			return
		}
		diagnosticsVersion := 0
		if s.phoneControl || (s.recorder != nil && s.recorder.State() == "active") {
			diagnosticsVersion = 1
		}
		s.connectionDiagnostics = diagnosticsVersion == 1
		direction, microphoneVersion := "desktop_playback", 0
		if s.microphone {
			direction, microphoneVersion = "phone_microphone", 1
		}
		duplexVersion := 0
		if s.duplex {
			direction, duplexVersion = "duplex", 1
		}
		timeoutsVersion := 0
		if s.version == 3 {
			timeoutsVersion = 1
		}
		phoneControlVersion := 0
		if s.phoneControl {
			phoneControlVersion = phonecontrol.Version
		}
		respond(w, map[string]any{"version": s.version, "session": secret, "sdp": offer, "diagnostics_version": diagnosticsVersion,
			"output_diagnostics_version": diagnosticsVersion, "connection_diagnostics_version": diagnosticsVersion, "session_lifecycle_version": 2,
			"output_control_diagnostics_version":  diagnosticsVersion,
			"ice_gathering_diagnostics_version":   s.gatheringVersion() * diagnosticsVersion,
			"trickle_ice_version":                 s.initialTrickleVersion(),
			"continuous_ice_version":              s.continuousVersion(),
			"media_transport_diagnostics_version": diagnosticsVersion,
			"route_selection_diagnostics_version": diagnosticsVersion,
			"tls_certificate_diagnostics_version": diagnosticsVersion,
			"audio_direction":                     direction, "microphone_return_version": microphoneVersion, "duplex_version": duplexVersion,
			"ice_restart_version": s.recoveryVersion(), "microphone_processing_version": 1,
			"connection_timeouts_version": timeoutsVersion, "recovery_window_ms": s.recoveryLimit().Milliseconds(),
			"phone_control_version": phoneControlVersion,
			"setup_window_ms":       s.setupLimit().Milliseconds(), "heartbeat_timeout_ms": s.heartbeatLimit().Milliseconds()})
		return
	}
	if !s.claimed || !equalToken(r.Header.Get("Authorization"), s.session) {
		http.Error(w, "Unauthorized", 401)
		return
	}
	switch {
	case r.URL.Path == "/recover-offer" && r.Method == http.MethodPost:
		s.recoverOffer(w, r)
	case r.URL.Path == "/recover-answer" && r.Method == http.MethodPost:
		s.recoverAnswer(w, r)
	case r.URL.Path == "/microphone" && r.Method == http.MethodPost:
		if !s.microphone || !s.answered || s.version != 3 {
			http.Error(w, "Microphone direction was not negotiated", 409)
			return
		}
		var request struct {
			Version int   `json:"version"`
			Muted   *bool `json:"muted"`
		}
		if !readJSONLimit(w, r, &request, 1024) || request.Version != 3 || request.Muted == nil {
			http.Error(w, "Invalid microphone control", 400)
			return
		}
		if !*request.Muted && (s.recovery.pending ||
			(s.continuous != nil && s.recovery.generation > 0 && !s.recovery.mediaReady)) {
			http.Error(w, "Connectivity recovery keeps the cable muted", 409)
			return
		}
		if err := s.peer.(rtc.MicrophonePeer).SetMicrophoneMuted(*request.Muted); err != nil {
			s.stop("microphone_bridge_failed")
			http.Error(w, "Windows microphone bridge unavailable", 500)
			return
		}
		// Control does not replace the heartbeat or revive a stalled session.
		respond(w, map[string]bool{"ok": true, "muted": *request.Muted})
	case r.URL.Path == "/answer" && r.Method == http.MethodPost:
		if s.answered || s.now().Sub(s.claimedAt) > s.setupLimit() {
			http.Error(w, "Answer unavailable", 409)
			return
		}
		var request struct {
			Version int    `json:"version"`
			SDP     string `json:"sdp"`
		}
		if !readJSON(w, r, &request) || request.Version != s.version || len(request.SDP) == 0 || len(request.SDP) > 65536 || strings.ContainsRune(request.SDP, 0) {
			http.Error(w, "Invalid answer", 400)
			return
		}
		if s.trickle != nil {
			sections, _, err := rtc.ParseICE(request.SDP)
			if err != nil {
				http.Error(w, "Invalid ICE answer", 400)
				return
			}
			s.trickle.RemoteSections = sections
		}
		if s.continuous != nil {
			if err := s.continuous.SetRemote(request.SDP); err != nil {
				http.Error(w, "Invalid ICE answer", 400)
				return
			}
		}
		if err := s.peer.Answer(request.SDP); err != nil {
			s.stop("answer_rejected")
			http.Error(w, "Answer rejected", 400)
			return
		}
		s.answered = true
		s.lastSeen = s.now()
		respond(w, map[string]bool{"ok": true})
	case r.URL.Path == "/status" && (r.Method == http.MethodGet || r.Method == http.MethodPost):
		if !s.answered {
			http.Error(w, "Answer required", 409)
			return
		}
		var report *diagnostics.AndroidReport
		var digest [32]byte
		duplicate := false
		var incomingICE *rtc.ICEDelta
		var incomingContinuous *rtc.ICESnapshot
		var incomingPhone *phonecontrol.Snapshot
		if r.Method == http.MethodPost {
			var request struct {
				Version    int                        `json:"version"`
				Android    *diagnostics.AndroidReport `json:"android"`
				ICE        *rtc.ICEDelta              `json:"ice,omitempty"`
				Continuous *rtc.ICESnapshot           `json:"continuous_ice,omitempty"`
				Phone      *phonecontrol.Snapshot     `json:"phone_control,omitempty"`
			}
			limit := int64(diagnostics.MaxReportBody)
			if s.trickle != nil || s.continuous != nil {
				limit = MaxBody
			}
			if s.phoneControl {
				limit += phonecontrol.MaxBody
			}
			if !readJSONLimit(w, r, &request, limit) || request.Version != s.version ||
				(request.Android == nil && request.ICE == nil && request.Continuous == nil && request.Phone == nil) ||
				(request.Phone != nil && (!s.phoneControl || request.Phone.Validate() != nil)) ||
				(request.ICE != nil && s.trickleVersion() != 1) ||
				(request.Continuous != nil && (s.continuous == nil || s.recovery.pending || request.ICE != nil)) {
				http.Error(w, "Invalid status update", 400)
				return
			}
			incomingICE = request.ICE
			incomingContinuous = request.Continuous
			incomingPhone = request.Phone
			if request.Android != nil {
				if !request.Android.Valid() ||
					(request.Android.Connection != nil && !s.connectionDiagnostics) ||
					(request.Android.ICEGathering != nil && !s.connectionDiagnostics) ||
					(request.Android.MediaTransport != nil && !s.connectionDiagnostics) ||
					(request.Android.RouteSelection != nil && !s.connectionDiagnostics) ||
					(request.Android.TLSVerification != nil && !s.connectionDiagnostics) ||
					(request.Android.LANRecovery != nil && s.recoveryVersion() != 1) ||
					(request.Android.Microphone != nil) != s.microphone ||
					(s.duplex && request.Android.Direction != "duplex") || (!s.duplex && request.Android.Direction == "duplex") {
					http.Error(w, "Invalid diagnostics", 400)
					return
				}
				canonical, _ := json.Marshal(request.Android) // Valid() excludes nonfinite numbers.
				digest = sha256.Sum256(canonical)
				duplicate = request.Android.Sequence == s.lastReport && digest == s.lastReportDigest
				if request.Android.Sequence < s.lastReport || (request.Android.Sequence == s.lastReport && !duplicate) {
					http.Error(w, "Stale diagnostics", 409)
					return
				}
				report = request.Android
			}
		}
		var outgoingICE *rtc.ICEDelta
		if incomingICE != nil {
			if s.recoveryExpired(w) {
				return
			}
			p := s.peer.(rtc.TricklePeer)
			if err := s.trickle.Accept(*incomingICE, p.AddICE); err != nil {
				http.Error(w, "Invalid ICE update", 400)
				return
			}
			sdp, complete, err := p.LocalICE()
			if err == nil {
				err = s.trickle.Observe(sdp, complete)
			}
			if err != nil {
				s.stop("ice_exchange_failed")
				http.Error(w, "ICE update unavailable", 500)
				return
			}
			delta := s.trickle.Delta()
			outgoingICE = &delta
		}
		var outgoingContinuous *rtc.ICESnapshot
		if incomingContinuous != nil {
			if s.recoveryExpired(w) {
				return
			}
			p := s.peer.(rtc.ContinuousPeer)
			if err := s.continuous.Accept(*incomingContinuous, p.AddICE, p.RemoveICE); err != nil {
				http.Error(w, "Invalid ICE snapshot", 400)
				return
			}
			sdp, _, err := p.LocalICE()
			if err == nil {
				err = s.continuous.Observe(sdp)
			}
			if err != nil {
				s.stop("ice_exchange_failed")
				http.Error(w, "ICE snapshot unavailable", 500)
				return
			}
			snapshot := s.continuous.Snapshot()
			outgoingContinuous = &snapshot
		}
		status, err := s.peer.Status()
		if err != nil {
			s.stop("statistics_unavailable")
			http.Error(w, "Statistics unavailable", 500)
			return
		}
		if err := s.checkMedia(status); err != nil {
			http.Error(w, "Audio session ended", 410)
			return
		}
		status = s.recoveryStatus(status)
		if incomingPhone != nil {
			s.phoneSettings.Receive(incomingPhone, s.now())
		}
		// An exact retry can recover a lost acknowledgment, but cannot keep an
		// abandoned session alive or write the same snapshot twice.
		if !duplicate {
			s.lastSeen = s.now()
		}
		logState := s.recorder.State()
		var sequence uint64
		if report != nil {
			sequence = report.Sequence
			if duplicate {
				logState = s.lastReportLog
			} else {
				s.lastReport = report.Sequence
				s.lastReportDigest = digest
				s.phoneReport = clonePhoneReport(report)
				s.phoneReportAt = s.now()
				logState = s.recorder.Playback(status, report)
				if s.phoneControl && logState != "accepted" && logState != "busy" {
					// Acknowledge live telemetry without claiming it was saved. New
					// clients keep reporting even when logging is disabled or fails.
					logState = "not_recorded"
				}
				s.lastReportLog = logState
			}
		}
		respond(w, struct {
			rtc.Status
			ReportLog      string               `json:"report_log"`
			ReportSequence uint64               `json:"report_sequence,omitempty"`
			ICE            *rtc.ICEDelta        `json:"ice,omitempty"`
			Continuous     *rtc.ICESnapshot     `json:"continuous_ice,omitempty"`
			PhoneCommand   *phonecontrol.Update `json:"phone_control_command,omitempty"`
		}{status, logState, sequence, outgoingICE, outgoingContinuous, s.phoneSettings.Command(s.now())})
	case r.URL.Path == "/stop" && r.Method == http.MethodPost:
		var request struct {
			Reason      string                   `json:"reason"`
			Diagnostics *diagnostics.ReceiverEnd `json:"diagnostics,omitempty"`
		}
		limit := int64(1024)
		if s.connectionDiagnostics {
			limit = diagnostics.MaxTerminalBody
		}
		if !readJSONLimit(w, r, &request, limit) {
			http.Error(w, "Invalid stop", 400)
			return
		}
		reason, ok := map[string]string{"": "receiver_stop", "user_stop": "receiver_stop",
			"user_pause": "receiver_pause", "focus_loss_transient": "receiver_focus_lost_transient",
			"focus_loss_permanent": "receiver_focus_lost_permanent",
			"focus_loss":           "receiver_focus_lost", "output_lost": "receiver_output_lost",
			"service_stopped": "receiver_service_stopped", "connection_failed": "receiver_failure"}[request.Reason]
		if !ok || (request.Diagnostics != nil && (!s.connectionDiagnostics || !request.Diagnostics.Valid(request.Reason))) {
			http.Error(w, "Invalid stop reason", 400)
			return
		}
		logState := "disabled"
		if request.Diagnostics != nil {
			status, err := s.peer.Status()
			if err == nil {
				logState = s.recorder.ReceiverEnd(&status, request.Diagnostics)
			} else {
				logState = s.recorder.ReceiverEnd(nil, request.Diagnostics)
			}
		}
		s.stop(reason)
		respond(w, map[string]any{"ok": true, "receiver_diagnostics": logState})
	default:
		http.Error(w, "Unsupported request", 404)
	}
}

func readJSON(w http.ResponseWriter, r *http.Request, value any) bool {
	return readJSONLimit(w, r, value, MaxBody)
}
func readJSONLimit(w http.ResponseWriter, r *http.Request, value any, limit int64) bool {
	r.Body = http.MaxBytesReader(w, r.Body, limit)
	decoder := json.NewDecoder(r.Body)
	decoder.DisallowUnknownFields()
	if decoder.Decode(value) != nil {
		return false
	}
	return decoder.Decode(new(any)) == io.EOF
}

func (s *Server) stop(reason string) { s.stopped = true; s.endReason = reason }

func (s *Server) EndReason() string {
	s.mu.Lock()
	defer s.mu.Unlock()
	return s.endReason
}
func respond(w http.ResponseWriter, value any) {
	// Large trickle/status replies exceed net/http's automatic length buffer.
	// Remote HTTP/1.0 must finish at a known byte count: aborting the server's
	// background read can close the WSS tunnel before TLS close_notify arrives.
	// Keep Android's strict rejection of unframed transport EOF intact.
	body, err := json.Marshal(value)
	if err != nil {
		http.Error(w, "Response unavailable", http.StatusInternalServerError)
		return
	}
	body = append(body, '\n')
	w.Header().Set("Content-Type", "application/json")
	w.Header().Set("Content-Length", strconv.Itoa(len(body)))
	_, _ = w.Write(body)
}

// Check is called by the host watchdog. Only successful authenticated status
// polls extend an accepted session; a vanished Android app cannot leave capture on.
func (s *Server) Check() (*rtc.Status, error) {
	s.mu.Lock()
	defer s.mu.Unlock()
	if s.stopped {
		return nil, errors.New("session ended")
	}
	if !s.claimed && !s.now().Before(s.expires) {
		s.stop("invitation_expired")
		return nil, errors.New("invitation expired")
	}
	if s.claimed && !s.answered && s.now().Sub(s.claimedAt) > s.setupLimit() {
		s.stop("pairing_timeout")
		return nil, errors.New("pairing timed out")
	}
	if !s.answered {
		return nil, nil
	}
	if s.now().Sub(s.lastSeen) > s.heartbeatLimit() {
		s.stop("receiver_timeout")
		return nil, errors.New("receiver stopped responding")
	}
	status, err := s.peer.Status()
	if err != nil {
		s.stop("statistics_unavailable")
		return nil, err
	}
	err = s.checkMedia(status)
	status = s.recoveryStatus(status)
	return &status, err
}

// The same deadline applies to watchdog ticks and status requests. A transient
// ICE disconnect may recover using existing candidates. Restart-capable paired
// peers may renegotiate within their original bounded window; neither path
// bypasses the independent heartbeat deadline.
func (s *Server) checkMedia(status rtc.Status) error {
	if status.BridgeFailed {
		s.stop("microphone_bridge_failed")
		return errors.New("microphone bridge failed")
	}
	limit := s.recoveryLimit()
	if status.CaptureFailed || status.State == "closed" ||
		(status.State == "failed" && s.recoveryVersion() == 0) ||
		(!s.disconnectedAt.IsZero() && s.now().Sub(s.disconnectedAt) >= limit) {
		s.stop("audio_session_lost")
		return errors.New("audio session lost")
	}
	// An early restart answer may leave the previous selected pair visible.
	// Continuous recovery needs both new ufrags on the SDK's selected pair before
	// clearing the original deadline or reopening the cable gate.
	current := s.continuous == nil || s.recovery.generation == 0 || status.ICEGenerationCurrent
	s.recovery.mediaReady = status.State == "connected" && !s.recovery.pending && current
	if s.recovery.mediaReady {
		s.disconnectedAt = time.Time{}
	} else if (status.State == "disconnected" || status.State == "failed" || !current) && s.disconnectedAt.IsZero() {
		s.disconnectedAt = s.now()
	}
	return nil
}

// end preserves a receiver/watchdog reason already recorded before host shutdown.
func (s *Server) end(reason string) string {
	s.mu.Lock()
	defer s.mu.Unlock()
	if !s.stopped {
		s.stop(reason)
	}
	return s.endReason
}
