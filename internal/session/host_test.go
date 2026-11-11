package session

import (
	"encoding/base64"
	"encoding/json"
	"errors"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"runtime"
	"strings"
	"sync/atomic"
	"testing"
	"time"

	"github.com/maskarauder/MicDrop/internal/diagnostics"
	"github.com/maskarauder/MicDrop/internal/rtc"
)

const reusableToken = "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"

type cyclePeer struct {
	fakePeer
	failOffer, failAnswer bool
	closes                atomic.Int32
	closing               chan struct{}
	release               chan struct{}
}

func (p *cyclePeer) Offer() (string, error) {
	if p.failOffer {
		return "", errors.New("failed")
	}
	return p.fakePeer.Offer()
}
func (p *cyclePeer) Answer(s string) error {
	if p.failAnswer {
		return errors.New("failed")
	}
	return p.fakePeer.Answer(s)
}
func (p *cyclePeer) Close() {
	p.closes.Add(1)
	if p.closing != nil {
		close(p.closing)
		<-p.release
	}
}

func hostCall(h *Host, method, path, token, body string) *httptest.ResponseRecorder {
	r := httptest.NewRequest(method, "https://192.168.1.2"+path, strings.NewReader(body))
	r.Header.Set("Authorization", "Bearer "+token)
	w := httptest.NewRecorder()
	h.ServeHTTP(w, r)
	return w
}
func hostClaim(t *testing.T, h *Host) (string, *managedSession) {
	t.Helper()
	w := hostCall(h, "POST", "/offer", reusableToken, `{"version":2}`)
	var response struct {
		Version int
		Session string
	}
	if w.Code != 200 || json.Unmarshal(w.Body.Bytes(), &response) != nil || response.Version != 2 || len(response.Session) != 43 {
		t.Fatalf("offer failed: %d %s", w.Code, w.Body.String())
	}
	h.mu.Lock()
	current := h.active
	h.mu.Unlock()
	return response.Session, current
}
func waitSession(t *testing.T, current *managedSession) {
	t.Helper()
	select {
	case <-current.done:
	case <-time.After(3 * time.Second):
		t.Fatal("session was not released")
	}
}
func hostAnswer(t *testing.T, h *Host, token string) {
	t.Helper()
	if w := hostCall(h, "POST", "/answer", token, `{"version":2,"sdp":"answer"}`); w.Code != 200 {
		t.Fatalf("answer: %d", w.Code)
	}
}

func TestReusableHostIsolatesPeersCredentialsReportsAndLogs(t *testing.T) {
	directory := filepath.Join(t.TempDir(), "sessions")
	var peers []*cyclePeer
	var paths []string
	h := NewHost(reusableToken, time.Now().Add(time.Hour), func(now time.Time, _ OfferOptions) (Resources, error) {
		l, path, err := diagnostics.CreateInDirectory(directory, diagnostics.DesktopCapture, now)
		p := &cyclePeer{fakePeer: fakePeer{status: rtc.Status{State: "connected", BytesSent: 123}}}
		peers = append(peers, p)
		paths = append(paths, path)
		return Resources{Peer: p, Log: l}, err
	})
	defer h.Close("test")
	h.Check()
	if _, err := os.Stat(directory); !os.IsNotExist(err) {
		t.Fatal("idle host created a log")
	}
	previous := ""
	for i := 0; i < 3; i++ {
		token, current := hostClaim(t, h)
		if token == reusableToken || token == previous {
			t.Fatal("session credential reused")
		}
		hostAnswer(t, h, token)
		if hostCall(h, "POST", "/offer", reusableToken, `{"version":2}`).Code != 423 || len(peers) != i+1 {
			t.Fatal("busy host allocated another session")
		}
		if previous != "" {
			for _, request := range []struct{ path, body string }{{"/stop", `{}`}, {"/answer", `{"version":2,"sdp":"old"}`},
				{"/status", strings.Replace(androidReport, `"version":1`, `"version":2`, 1)}} {
				if hostCall(h, "POST", request.path, previous, request.body).Code != 401 {
					t.Fatal("stale session reached successor")
				}
			}
		}
		body := strings.Replace(androidReport, `"version":1`, `"version":2`, 1)
		for j := 0; j < 2; j++ { // duplicate retry is acknowledged but recorded once
			if w := hostCall(h, "POST", "/status", token, body); w.Code != 200 || !strings.Contains(w.Body.String(), `"report_sequence":1`) {
				t.Fatal("new report sequence failed")
			}
		}
		if hostCall(h, "POST", "/stop", token, `{}`).Code != 200 {
			t.Fatal("stop failed")
		}
		waitSession(t, current)
		if peers[i].closes.Load() != 1 {
			t.Fatal("peer not closed exactly once")
		}
		data, err := os.ReadFile(paths[i])
		if err != nil {
			t.Fatal(err)
		}
		for _, expected := range []string{`"type":"session_start"`, `"type":"session_end"`, `"type":"playback"`, `"reason":"receiver_stop"`} {
			if strings.Count(string(data), expected) != 1 {
				t.Fatalf("missing/duplicated %s", expected)
			}
		}
		for _, secret := range []string{token, reusableToken, "192.168.1.2", `"sdp"`} {
			if strings.Contains(string(data), secret) {
				t.Fatal("secret entered log")
			}
		}
		previous = token
	}
	entries, err := os.ReadDir(directory)
	if err != nil || len(entries) != 3 {
		t.Fatal("logs overwritten or extra idle logs")
	}
}

func TestHostRejectsBeforeAllocatingResources(t *testing.T) {
	calls := 0
	now := time.Now()
	h := NewHost(reusableToken, now.Add(time.Minute), func(time.Time, OfferOptions) (Resources, error) {
		calls++
		return Resources{}, errors.New("unexpected")
	})
	h.now = func() time.Time { return now }
	for _, body := range []string{`{"version":1}`, `{"version":2,"extra":true}`, `{"version":2} {}`, strings.Repeat(" ", 1024) + `{"version":2}`} {
		if hostCall(h, "POST", "/offer", reusableToken, body).Code != 400 {
			t.Fatal("invalid offer accepted")
		}
	}
	if hostCall(h, "POST", "/offer", strings.Repeat("b", 43), `{"version":2}`).Code != 401 {
		t.Fatal("unauthenticated offer")
	}
	if hostCall(h, "POST", "/offer?token=secret", reusableToken, `{"version":2}`).Code != 400 {
		t.Fatal("query accepted")
	}
	r := httptest.NewRequest("POST", "http://192.168.1.2/offer", strings.NewReader(`{"version":2}`))
	w := httptest.NewRecorder()
	h.ServeHTTP(w, r)
	if w.Code != 426 {
		t.Fatal("plaintext accepted")
	}
	now = now.Add(time.Minute)
	if hostCall(h, "POST", "/offer", reusableToken, `{"version":2}`).Code != 410 {
		t.Fatal("expiry ignored")
	}
	if _, err := h.Check(); err == nil || calls != 0 {
		t.Fatal("idle expiry allocated resources or stayed open")
	}
}

func TestHostReleasesFailuresAndAcceptsNextSession(t *testing.T) {
	for _, failure := range []string{"initialize", "offer", "answer", "pairing_timeout", "receiver_timeout", "media"} {
		t.Run(failure, func(t *testing.T) {
			now := time.Now()
			attempt := 0
			var failed *managedSession
			h := NewHost(reusableToken, now.Add(time.Hour), func(time.Time, OfferOptions) (Resources, error) {
				attempt++
				p := &cyclePeer{fakePeer: fakePeer{status: rtc.Status{State: "connected"}}}
				if attempt == 1 {
					p.failOffer = failure == "offer"
					p.failAnswer = failure == "answer"
					if failure == "media" {
						p.status.State = "failed"
					}
					if failure == "initialize" {
						return Resources{Peer: p}, errors.New("failed")
					}
				}
				return Resources{Peer: p}, nil
			})
			h.now = func() time.Time { return now }
			defer h.Close("test")
			// Preserve a handle even if setup fails and cleanup is very fast.
			factory := h.factory
			h.factory = func(at time.Time, _ OfferOptions) (Resources, error) {
				h.mu.Lock()
				failed = h.active
				h.mu.Unlock()
				return factory(at, OfferOptions{})
			}
			w := hostCall(h, "POST", "/offer", reusableToken, `{"version":2}`)
			if failure == "initialize" || failure == "offer" {
				if w.Code != 500 {
					t.Fatal("setup failure hidden")
				}
			} else {
				var response struct{ Session string }
				json.Unmarshal(w.Body.Bytes(), &response)
				if failure != "pairing_timeout" {
					hostCall(h, "POST", "/answer", response.Session, `{"version":2,"sdp":"answer"}`)
				}
				if failure == "pairing_timeout" {
					now = now.Add(46 * time.Second)
				}
				if failure == "receiver_timeout" {
					now = now.Add(16 * time.Second)
				}
				if _, err := h.Check(); err != nil {
					t.Fatal("session failure ended listener")
				}
			}
			waitSession(t, failed)
			token, _ := hostClaim(t, h)
			hostAnswer(t, h, token)
			if attempt != 2 {
				t.Fatal("host did not recover")
			}
		})
	}
}

func TestHostBusyUntilNativeCleanupCompletes(t *testing.T) {
	p := &cyclePeer{closing: make(chan struct{}), release: make(chan struct{})}
	h := NewHost(reusableToken, time.Now().Add(time.Hour), func(time.Time, OfferOptions) (Resources, error) { return Resources{Peer: p}, nil })
	token, current := hostClaim(t, h)
	if hostCall(h, "POST", "/stop", token, `{}`).Code != 200 {
		t.Fatal("stop acknowledgment blocked")
	}
	<-p.closing
	if hostCall(h, "POST", "/offer", reusableToken, `{"version":2}`).Code != 423 {
		t.Fatal("native lifetimes overlap")
	}
	close(p.release)
	waitSession(t, current)
	h.Close("test")
}

func TestHostShutdownDuringInitialization(t *testing.T) {
	entered, release := make(chan struct{}), make(chan struct{})
	p := &cyclePeer{}
	h := NewHost(reusableToken, time.Now().Add(time.Hour), func(time.Time, OfferOptions) (Resources, error) {
		close(entered)
		<-release
		return Resources{Peer: p}, nil
	})
	response := make(chan int, 1)
	go func() { response <- hostCall(h, "POST", "/offer", reusableToken, `{"version":2}`).Code }()
	<-entered
	if hostCall(h, "POST", "/offer", reusableToken, `{"version":2}`).Code != 423 {
		t.Fatal("initializing session not busy")
	}
	closed := make(chan struct{})
	go func() { h.Close("host_stopped"); close(closed) }()
	// Synchronize with the closed state without sleeps or changing production state.
	for {
		h.mu.Lock()
		stopped := h.closed != ""
		h.mu.Unlock()
		if stopped {
			break
		}
		runtime.Gosched()
	}
	close(release)
	if <-response != 410 {
		t.Fatal("shutdown allowed offer")
	}
	<-closed
	if p.closes.Load() != 1 || p.offers != 0 {
		t.Fatal("initialization leaked native resources")
	}
}

func TestHostRequestBudgetSurvivesSessionBoundary(t *testing.T) {
	h := NewHost(reusableToken, time.Now().Add(time.Hour), func(time.Time, OfferOptions) (Resources, error) { return Resources{Peer: &cyclePeer{}}, nil })
	defer h.Close("test")
	token, current := hostClaim(t, h)
	hostCall(h, "POST", "/stop", token, `{}`)
	waitSession(t, current)
	for i := 0; i < 118; i++ {
		if hostCall(h, "GET", "/status", "", "").Code == 429 {
			t.Fatal("budget too small")
		}
	}
	if hostCall(h, "POST", "/offer", reusableToken, `{"version":2}`).Code != 429 {
		t.Fatal("new session reset listener budget")
	}
}

func TestReusableInvitationVersionIsExplicit(t *testing.T) {
	i := Invitation{Host: "192.168.1.2", Port: 9844, Token: reusableToken, Fingerprint: strings.Repeat("0", 64)}
	if !strings.HasPrefix(i.String(), "micdrop://v1/") {
		t.Fatal("legacy semantics changed")
	}
	i.ExpiresAt = time.Now().Add(time.Hour).Unix()
	link := i.String()
	if !strings.HasPrefix(link, "micdrop://v2/") {
		t.Fatal("reusable version missing")
	}
	raw, err := base64.RawURLEncoding.DecodeString(strings.TrimPrefix(link, "micdrop://v2/"))
	var decoded Invitation
	if err != nil || json.Unmarshal(raw, &decoded) != nil || decoded != i {
		t.Fatal("link lost expiry or trust data")
	}
}

func TestInitializationFailureStillFinalizesItsLog(t *testing.T) {
	directory := t.TempDir()
	var path string
	ended := make(chan error, 1)
	h := NewHost(reusableToken, time.Now().Add(time.Hour), func(now time.Time, _ OfferOptions) (Resources, error) {
		l, name, err := diagnostics.CreateInDirectory(directory, diagnostics.DesktopCapture, now)
		if err != nil {
			t.Fatal(err)
		}
		path = name
		return Resources{Log: l, End: func(_ string, err error, _ *rtc.Status) { ended <- err }}, errors.New("native setup failed")
	})
	if hostCall(h, "POST", "/offer", reusableToken, `{"version":2}`).Code != 500 {
		t.Fatal("setup failure hidden")
	}
	if err := <-ended; err != nil {
		t.Fatal(err)
	}
	h.Close("test")
	data, err := os.ReadFile(path)
	if err != nil || !strings.Contains(string(data), `"reason":"session_initialization_failed"`) ||
		strings.Count(string(data), `"type":"session_start"`) != 1 || strings.Count(string(data), `"type":"session_end"`) != 1 {
		t.Fatal("failed setup log did not finalize")
	}
}

func TestHostExpiryEndsActiveSessionAndRevokesCredential(t *testing.T) {
	now := time.Now()
	p := &cyclePeer{fakePeer: fakePeer{status: rtc.Status{State: "connected"}}}
	h := NewHost(reusableToken, now.Add(time.Minute), func(time.Time, OfferOptions) (Resources, error) { return Resources{Peer: p}, nil })
	h.now = func() time.Time { return now }
	token, current := hostClaim(t, h)
	hostAnswer(t, h, token)
	now = now.Add(time.Minute)
	if _, err := h.Check(); err == nil {
		t.Fatal("host lifetime was extended by playback")
	}
	waitSession(t, current)
	if p.closes.Load() != 1 || current.server.EndReason() != "connection_link_expired" {
		t.Fatal("expiry did not release active peer")
	}
	if hostCall(h, "POST", "/offer", reusableToken, `{"version":2}`).Code != 410 {
		t.Fatal("expired credential reused")
	}
}

type budgetAuthority struct{}

func (budgetAuthority) Client(r *http.Request) (string, bool) {
	key := r.Header.Get("X-Test-Client")
	return key, key == "phone-a" || key == "phone-b"
}
func (budgetAuthority) Allowed(key string) bool { return key == "phone-a" || key == "phone-b" }
func (budgetAuthority) Enrollment(w http.ResponseWriter, _ *http.Request) {
	w.WriteHeader(202)
}

func TestPairedHostIsolatesUnauthenticatedAndContendingRequestBudgets(t *testing.T) {
	h, err := NewPairedHost(budgetAuthority{}, func(time.Time, OfferOptions) (Resources, error) {
		return Resources{Peer: &cyclePeer{fakePeer: fakePeer{status: rtc.Status{State: "connected"}}}}, nil
	})
	if err != nil {
		t.Fatal(err)
	}
	defer h.Close("test")

	call := func(method, path, client, token, body string) *httptest.ResponseRecorder {
		r := httptest.NewRequest(method, "https://192.168.1.2"+path, strings.NewReader(body))
		if client != "" {
			r.Header.Set("X-Test-Client", client)
		}
		if token != "" {
			r.Header.Set("Authorization", "Bearer "+token)
		}
		w := httptest.NewRecorder()
		h.ServeHTTP(w, r)
		return w
	}

	w := call("POST", "/offer", "phone-a", "", `{"version":3}`)
	var offer struct{ Session string }
	if w.Code != 200 || json.Unmarshal(w.Body.Bytes(), &offer) != nil || len(offer.Session) != 43 {
		t.Fatalf("paired offer failed: %d %s", w.Code, w.Body.String())
	}
	if call("POST", "/answer", "phone-a", offer.Session, `{"version":3,"sdp":"answer"}`).Code != 200 {
		t.Fatal("paired answer failed")
	}

	// Exhaust the unauthenticated/contending bucket with revoked peers, /pair, and a second paired phone.
	for i := 0; i < 60; i++ {
		_ = call("GET", "/status", "revoked-phone", "", "")
		_ = call("POST", "/pair", "", "", `{}`)
		_ = call("POST", "/offer", "phone-b", "", `{"version":3}`)
	}
	if call("GET", "/status", "revoked-phone", "", "").Code != 429 {
		t.Fatal("unauthenticated flood was not rate limited")
	}
	if call("POST", "/pair", "", "", `{}`).Code != 429 {
		t.Fatal("pairing flood was not rate limited")
	}
	if call("POST", "/offer", "phone-b", "", `{"version":3}`).Code != 429 {
		t.Fatal("contending device flood was not rate limited")
	}

	// Active paired device retains its full heartbeat and stop budget.
	body := strings.Replace(androidReport, `"version":1`, `"version":3`, 1)
	if status := call("POST", "/status", "phone-a", offer.Session, body); status.Code != 200 {
		t.Fatalf("active session starved by unauthenticated/contending traffic: %d", status.Code)
	}
	if stop := call("POST", "/stop", "phone-a", offer.Session, `{}`); stop.Code != 200 {
		t.Fatalf("active session stop starved: %d", stop.Code)
	}
}
