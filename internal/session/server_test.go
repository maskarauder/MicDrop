package session

import (
	"crypto/sha256"
	"crypto/tls"
	"crypto/x509"
	"encoding/hex"
	"encoding/json"
	"net"
	"net/http/httptest"
	"strings"
	"testing"
	"time"

	"github.com/maskarauder/MicDrop/internal/rtc"
)

type fakePeer struct {
	offers, answers int
	status          rtc.Status
}

func (p *fakePeer) Offer() (string, error)      { p.offers++; return "test offer", nil }
func (p *fakePeer) Answer(string) error         { p.answers++; return nil }
func (p *fakePeer) Status() (rtc.Status, error) { return p.status, nil }
func (p *fakePeer) Close()                      {}

func call(s *Server, path, token, body string) *httptest.ResponseRecorder {
	method := "POST"
	if path == "/status" {
		method = "GET"
	}
	r := httptest.NewRequest(method, "https://192.168.1.2"+path, strings.NewReader(body))
	r.Header.Set("Authorization", "Bearer "+token)
	r.TLS = &tls.ConnectionState{}
	w := httptest.NewRecorder()
	s.ServeHTTP(w, r)
	return w
}
func claim(t *testing.T, s *Server, token string) string {
	t.Helper()
	w := call(s, "/offer", token, `{"version":1}`)
	if w.Code != 200 {
		t.Fatalf("claim failed: %d", w.Code)
	}
	var reply struct {
		Session string `json:"session"`
	}
	if err := json.Unmarshal(w.Body.Bytes(), &reply); err != nil || len(reply.Session) != 43 {
		t.Fatal("missing session token")
	}
	return reply.Session
}
func TestAuthenticatedSingleUseSession(t *testing.T) {
	now := time.Now()
	token := strings.Repeat("a", 43)
	peer := &fakePeer{status: rtc.Status{State: "connected"}}
	s := New(peer, token, now)
	s.now = func() time.Time { return now }
	if call(s, "/offer", strings.Repeat("b", 43), `{"version":1}`).Code != 401 || peer.offers != 0 {
		t.Fatal("unauthorized native access")
	}
	if call(s, "/offer", token, `{"version":2}`).Code != 400 {
		t.Fatal("unsupported protocol accepted")
	}
	session := claim(t, s, token)
	if session == token || peer.offers != 1 {
		t.Fatal("invitation was not exchanged")
	}
	if call(s, "/offer", token, `{"version":1}`).Code != 401 {
		t.Fatal("invitation replay accepted")
	}
	answer := `{"version":1,"sdp":"answer"}`
	if call(s, "/answer", token, answer).Code != 401 || peer.answers != 0 {
		t.Fatal("invitation reused as session credential")
	}
	if call(s, "/answer", session, answer).Code != 200 || peer.answers != 1 {
		t.Fatal("valid answer failed")
	}
	if call(s, "/answer", session, answer).Code != 409 || peer.answers != 1 {
		t.Fatal("answer replay accepted")
	}
	now = now.Add(10 * time.Second)
	if call(s, "/status", session, "").Code != 200 {
		t.Fatal("heartbeat failed")
	}
	now = now.Add(10 * time.Second)
	if _, err := s.Check(); err != nil {
		t.Fatal("heartbeat did not extend session")
	}
	now = now.Add(6 * time.Second)
	if _, err := s.Check(); err == nil {
		t.Fatal("receiver timeout left session active")
	}
	if call(s, "/status", session, "").Code != 410 {
		t.Fatal("expired session revived")
	}
}
func TestRejectUnboundedAndMalformedControl(t *testing.T) {
	token := strings.Repeat("a", 43)
	for _, body := range []string{`{"version":1,"unknown":true}`, `{"version":1} {}`, strings.Repeat(" ", MaxBody) + `{"version":1}`} {
		peer := &fakePeer{}
		s := New(peer, token, time.Now())
		if call(s, "/offer", token, body).Code != 400 || peer.offers != 0 {
			t.Fatal("malformed request reached peer")
		}
	}
	s := New(&fakePeer{}, token, time.Now())
	session := claim(t, s, token)
	for _, sdp := range []string{strings.Repeat("x", 65537), "invalid\x00SDP"} {
		body, _ := json.Marshal(map[string]any{"version": 1, "sdp": sdp})
		if call(s, "/answer", session, string(body)).Code != 400 {
			t.Fatal("invalid SDP length or NUL accepted")
		}
	}
	r := httptest.NewRequest("POST", "http://192.168.1.2/offer", strings.NewReader(`{"version":1}`))
	w := httptest.NewRecorder()
	s.ServeHTTP(w, r)
	if w.Code != 426 {
		t.Fatal("plaintext accepted")
	}
}

func TestLateRequestCannotReviveSession(t *testing.T) {
	for _, answered := range []bool{false, true} {
		now := time.Now()
		token := strings.Repeat("a", 43)
		peer := &fakePeer{status: rtc.Status{State: "connected"}}
		s := New(peer, token, now)
		s.now = func() time.Time { return now }
		credential := claim(t, s, token)
		if answered {
			if call(s, "/answer", credential, `{"version":1,"sdp":"answer"}`).Code != 200 {
				t.Fatal("valid answer failed")
			}
			now = now.Add(16 * time.Second)
			if call(s, "/status", credential, "").Code != 410 {
				t.Fatal("late heartbeat revived an expired session")
			}
		} else {
			now = now.Add(46 * time.Second)
			if call(s, "/answer", credential, `{"version":1,"sdp":"answer"}`).Code != 410 || peer.answers != 0 {
				t.Fatal("late answer reached the native peer")
			}
		}
	}
}
func TestExpiryStopAndTransportFailure(t *testing.T) {
	now := time.Now()
	token := strings.Repeat("a", 43)
	s := New(&fakePeer{}, token, now)
	s.now = func() time.Time { return now.Add(5 * time.Minute) }
	if call(s, "/offer", token, `{"version":1}`).Code != 401 {
		t.Fatal("expired invitation accepted")
	}
	s = New(&fakePeer{}, token, now)
	s.now = func() time.Time { return now }
	claim(t, s, token)
	now = now.Add(46 * time.Second)
	if _, err := s.Check(); err == nil {
		t.Fatal("unfinished pairing did not expire")
	}
	for _, state := range []string{"failed", "closed"} {
		s = New(&fakePeer{status: rtc.Status{State: state}}, token, now)
		session := claim(t, s, token)
		call(s, "/answer", session, `{"version":1,"sdp":"answer"}`)
		if _, err := s.Check(); err == nil {
			t.Fatalf("%s not terminal", state)
		}
	}
	s = New(&fakePeer{}, token, now)
	session := claim(t, s, token)
	if call(s, "/stop", session, `{}`).Code != 200 {
		t.Fatal("stop failed")
	}
	if _, err := s.Check(); err == nil {
		t.Fatal("stop left session active")
	}
}
func TestEphemeralTLSIdentity(t *testing.T) {
	now := time.Now()
	ip := net.ParseIP("192.168.1.2")
	identity, pin, err := Identity(ip, now)
	if err != nil {
		t.Fatal(err)
	}
	leaf, err := x509.ParseCertificate(identity.Certificate[0])
	if err != nil {
		t.Fatal(err)
	}
	actual := sha256.Sum256(leaf.Raw)
	if pin != hex.EncodeToString(actual[:]) {
		t.Fatal("invitation pin mismatches TLS identity")
	}
	roots := x509.NewCertPool()
	roots.AddCert(leaf)
	if _, err = leaf.Verify(x509.VerifyOptions{Roots: roots, DNSName: ip.String(), CurrentTime: now}); err != nil {
		t.Fatal(err)
	}
	if leaf.VerifyHostname("192.168.1.3") == nil {
		t.Fatal("wrong host accepted")
	}
	if _, err = leaf.Verify(x509.VerifyOptions{Roots: roots, DNSName: ip.String(), CurrentTime: now.Add(25 * time.Hour)}); err == nil {
		t.Fatal("expired identity accepted")
	}
	other, _, err := Identity(ip, now)
	if err != nil {
		t.Fatal(err)
	}
	if string(other.Certificate[0]) == string(leaf.Raw) {
		t.Fatal("ephemeral identity reused")
	}
}
