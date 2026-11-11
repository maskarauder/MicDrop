package session

import (
	"errors"
	"fmt"
	"io"
	"net/http"
	"strings"
	"sync"
	"time"

	"github.com/maskarauder/MicDrop/internal/diagnostics"
	"github.com/maskarauder/MicDrop/internal/rtc"
)

// Resources belong to one accepted offer, even when native setup fails. The
// factory opens its log before its peer. End runs after both have been closed.
// A bridge failure supplies the status captured before native release when available.
type Resources struct {
	ID         uint64 // Local presentation generation; never a session credential.
	Peer       rtc.Peer
	Log        *diagnostics.Log
	End        func(reason string, logError error, finalStatus *rtc.Status)
	LogWarning func()
}

// OfferOptions are authenticated before resources are allocated. The SDK's
// gathering policy must be selected at creation, before any local description.
type OfferOptions struct {
	ContinuousICE bool
	ClientKey     string // Authenticated paired identity, never supplied by the JSON body.
	Resuming      bool   // Presentation hint only; grants no media or microphone permission.
	ResumeReason  string // "", manual, automatic or focus_regain; set only while Resuming.
}
type Factory func(time.Time, OfferOptions) (Resources, error)

type managedSession struct {
	client    string  // v3: SPKI identity that owns every request for this stream.
	attempt   string  // optional client nonce, scoped to this connection attempt
	cancelled bool    // protected by Host.mu, including while the factory runs
	server    *Server // published under Host.mu after factory completion
	resources Resources
	warn      sync.Once
	finish    sync.Once
	done      chan struct{}
}

// Host accepts sequential streams using a v2 credential. An active stream has
// its own Server, report sequence, peer, log and fresh random session credential.
type Host struct {
	authority         PairedAuthority
	mu                sync.Mutex
	active            *managedSession
	closed            string
	invitation        string
	expires           time.Time
	factory           Factory
	microphoneFactory Factory
	duplexFactory     Factory
	limits            *requestLimits
	unauthLimits      *requestLimits
	now               func() time.Time
	cancelledOffers   map[offerAttempt]time.Time
}

type PairedAuthority interface {
	Client(*http.Request) (string, bool)
	Allowed(string) bool
	Enrollment(http.ResponseWriter, *http.Request)
}

func NewPairedHost(authority PairedAuthority, factory Factory) (*Host, error) {
	secret, err := Secret() // Internal adapter credential; never sent to a client.
	if err != nil {
		return nil, err
	}
	h := NewHost(secret, time.Date(9999, 1, 1, 0, 0, 0, 0, time.UTC), factory)
	h.authority = authority
	return h, nil
}

func NewHost(invitation string, expires time.Time, factory Factory) *Host {
	return &Host{invitation: invitation, expires: expires, factory: factory,
		limits: newRequestLimits(), unauthLimits: newRequestLimits(), now: time.Now}
}

// Configure before serving. Return streaming is available only to paired v3
// clients that explicitly request this direction on a fresh offer.
func (h *Host) EnableMicrophoneReturn(factory Factory) { h.microphoneFactory = factory }

func (h *Host) EnableDuplex(factory Factory) { h.duplexFactory = factory }

func (h *Host) ServeHTTP(w http.ResponseWriter, r *http.Request) {
	if !checkRequest(w, r) {
		return
	}
	now := h.now()
	client := ""
	limits := h.limits
	if h.authority != nil {
		if r.URL.Path == "/pair" {
			if !h.unauthLimits.acquire(w, now) {
				return
			}
			defer h.unauthLimits.leave()
			h.authority.Enrollment(w, r)
			return
		}
		var allowed bool
		client, allowed = h.authority.Client(r)
		if !allowed {
			if !h.unauthLimits.acquire(w, now) {
				return
			}
			defer h.unauthLimits.leave()
			http.Error(w, "Device is not paired or was revoked", 403)
			return
		}
		h.mu.Lock()
		contending := h.active != nil && h.active.client != client
		h.mu.Unlock()
		if contending {
			limits = h.unauthLimits
		}
	}
	if !limits.acquire(w, now) {
		return
	}
	defer limits.leave()
	if !now.Before(h.expires) {
		http.Error(w, "Connection link expired", 410)
		return
	}
	if r.URL.Path == "/offer" && r.Method == http.MethodPost {
		h.offer(w, r, client)
		return
	}
	if r.URL.Path == "/cancel-offer" && r.Method == http.MethodPost {
		h.cancelOffer(w, r, client)
		return
	}
	h.mu.Lock()
	current, closed := h.active, h.closed != ""
	var s *Server
	if current != nil {
		s = current.server
	}
	h.mu.Unlock()
	if closed || s == nil {
		http.Error(w, "No active session", 410)
		return
	}
	if h.authority != nil && current.client != client {
		http.Error(w, "Session belongs to another device", 403)
		return
	}
	s.serve(w, r)
	if reason := s.EndReason(); reason != "" {
		h.finish(current, reason)
	}
}

func (h *Host) offer(w http.ResponseWriter, r *http.Request, client string) {
	version := 2
	if h.authority != nil {
		version = 3
	}
	if (version == 2 && !equalToken(r.Header.Get("Authorization"), h.invitation)) ||
		(version == 3 && r.Header.Get("Authorization") != "") {
		http.Error(w, "Connection link rejected", 401)
		return
	}
	var request offerRequest
	if !readJSONLimit(w, r, &request, 1024) || !request.valid(version) {
		http.Error(w, "Invalid protocol version", 400)
		return
	}
	if _, valid := readConnectionTimeouts(r, version); !valid {
		http.Error(w, "Invalid connection timeouts", 400)
		return
	}
	if _, valid := readPhoneControl(r, version); !valid {
		http.Error(w, "Invalid phone control capability", 400)
		return
	}
	attempt, ok := readOfferAttempt(r, false)
	if !ok {
		http.Error(w, "Invalid connection attempt", 400)
		return
	}
	resume, reason, ok := readSessionResume(r, version)
	if !ok {
		http.Error(w, "Invalid session resume hint", 400)
		return
	}
	factory := h.factory
	if request.Duplex == 1 {
		if h.duplexFactory == nil {
			http.Error(w, "Windows duplex is not configured", 409)
			return
		}
		factory = h.duplexFactory
	} else if request.MicrophoneReturn == 1 {
		if h.microphoneFactory == nil {
			http.Error(w, "Windows microphone return is not configured", 409)
			return
		}
		factory = h.microphoneFactory
	}
	h.mu.Lock()
	if h.closed != "" {
		h.mu.Unlock()
		http.Error(w, "Host stopped", 410)
		return
	}
	h.pruneCancelledOffers()
	if _, cancelled := h.cancelledOffers[offerAttempt{client, attempt}]; cancelled && attempt != "" {
		h.mu.Unlock()
		http.Error(w, "Connection attempt cancelled", 410)
		return
	}
	if h.active != nil {
		h.mu.Unlock()
		http.Error(w, "A session is active or finishing; retry after it stops", 423)
		return
	}
	current := &managedSession{client: client, attempt: attempt, done: make(chan struct{})}
	h.active = current // reserve before disk/native work, without holding the host mutex
	h.mu.Unlock()
	resources, err := factory(h.now(), OfferOptions{ContinuousICE: version == 3 && r.Header.Get("X-MicDrop-Trickle-ICE") == "1" && r.Header.Get(rtc.ContinuousHeader) == "1", ClientKey: client, Resuming: resume, ResumeReason: reason})
	h.mu.Lock()
	current.resources = resources
	closed := h.closed
	cancelled := current.cancelled
	if err == nil && resources.Peer != nil {
		current.server = New(resources.Peer, h.invitation, h.now(), WithDiagnostics(resources.Log))
		current.server.version = version
		current.server.expires = h.expires
		current.server.now = h.now
		current.server.microphone = request.MicrophoneReturn == 1
		current.server.duplex = request.Duplex == 1
	}
	s := current.server
	h.mu.Unlock()
	if closed != "" {
		h.finish(current, closed)
		http.Error(w, "Host stopped", 410)
		return
	}
	if cancelled {
		h.finish(current, "offer_cancelled")
		http.Error(w, "Connection attempt cancelled", 410)
		return
	}
	if s == nil {
		h.finish(current, "session_initialization_failed")
		http.Error(w, "Session unavailable", 500)
		return
	}
	if h.authority != nil && !h.authority.Allowed(client) {
		h.finish(current, "device_revoked")
		http.Error(w, "Device authorization ended", 403)
		return
	}
	// The request was bounded, parsed and authenticated before allocating any
	// resources. Core session handling still enforces its own version/expiry.
	r = r.Clone(r.Context())
	r.Body = io.NopCloser(strings.NewReader(fmt.Sprintf(`{"version":%d,"microphone_return_version":%d,"duplex_version":%d}`, version, request.MicrophoneReturn, request.Duplex)))
	if version == 3 {
		r.Header.Set("Authorization", "Bearer "+h.invitation)
	}
	s.serve(w, r)
	if reason := s.EndReason(); reason != "" {
		h.finish(current, reason)
	}
}

// Cleanup is separate from the HTTP handler so disk finalization cannot delay
// Stop's acknowledgment. Busy remains true until native release and log close.
func (h *Host) finish(current *managedSession, reason string) {
	current.finish.Do(func() {
		go func() {
			if current.server != nil {
				reason = current.server.end(reason)
			}
			var finalStatus *rtc.Status
			if current.resources.Peer != nil {
				// A control/status request can end an audio path before the watchdog's
				// first tick. Preserve the native failure before releasing the peer.
				if reason == "microphone_bridge_failed" || reason == "audio_session_lost" || reason == "offer_failed" {
					if status, err := current.resources.Peer.Status(); err == nil {
						finalStatus = &status
						current.resources.Log.Host(status)
					}
				}
				current.resources.Peer.Close()
			}
			err := current.resources.Log.Close(reason)
			if current.resources.End != nil {
				current.resources.End(reason, err, finalStatus)
			}
			h.mu.Lock()
			if h.active == current {
				h.active = nil
			}
			close(current.done)
			h.mu.Unlock()
		}()
	})
}

// Check runs on the host watchdog. Session failure releases that session; only
// credential expiry ends the listener. A nil status means the host is idle/setup.
func (h *Host) Check() (*rtc.Status, error) {
	if !h.now().Before(h.expires) {
		h.Close("connection_link_expired")
		return nil, errors.New("connection link expired; restart the host for a new link")
	}
	h.mu.Lock()
	current := h.active
	var s *Server
	if current != nil {
		s = current.server
	}
	h.mu.Unlock()
	if s == nil {
		return nil, nil
	}
	if h.authority != nil && !h.authority.Allowed(current.client) {
		h.finish(current, "device_revoked")
		return nil, nil
	}
	status, err := s.Check()
	if status != nil {
		current.resources.Log.Host(*status)
	}
	if state := current.resources.Log.State(); (state == "full" || state == "unavailable") && current.resources.LogWarning != nil {
		current.warn.Do(current.resources.LogWarning)
	}
	if err != nil {
		h.finish(current, s.EndReason())
	}
	return status, nil
}

// Revocation also interrupts an active stream. A factory still in progress
// rechecks authorization before returning an offer; Check is a second guard.
func (h *Host) Revoke(client string) {
	h.mu.Lock()
	current := h.active
	ready := current != nil && current.client == client && current.server != nil
	h.mu.Unlock()
	if ready {
		h.finish(current, "device_revoked")
	}
}

func (h *Host) Close(reason string) {
	h.mu.Lock()
	if h.closed == "" {
		h.closed = reason
	}
	current := h.active
	ready := current != nil && current.server != nil
	h.mu.Unlock()
	if current != nil {
		if ready {
			h.finish(current, reason)
		}
		// An in-progress factory observes closed and performs cleanup itself.
		<-current.done
	}
}
