package pairing

import (
	"bytes"
	"crypto/ecdsa"
	"crypto/elliptic"
	"crypto/rand"
	"crypto/tls"
	"crypto/x509"
	"encoding/json"
	"errors"
	"io"
	"math/big"
	"net"
	"net/http"
	"net/http/httptest"
	"os"
	"strings"
	"sync/atomic"
	"testing"
	"time"

	"github.com/maskarauder/MicDrop/internal/identity"
	"github.com/maskarauder/MicDrop/internal/rtc"
	"github.com/maskarauder/MicDrop/internal/session"
)

type memoryStore struct {
	data []byte
	fail bool
}

func (s *memoryStore) Load() ([]byte, error) {
	if s.data == nil {
		return nil, os.ErrNotExist
	}
	return append([]byte(nil), s.data...), nil
}
func (s *memoryStore) Save(b []byte) error {
	if s.fail {
		return errors.New("disk failed")
	}
	s.data = append([]byte(nil), b...)
	return nil
}

func testCertificate(t *testing.T, client bool) tls.Certificate {
	t.Helper()
	key, err := ecdsa.GenerateKey(elliptic.P256(), rand.Reader)
	if err != nil {
		t.Fatal(err)
	}
	now := time.Now()
	cert := &x509.Certificate{SerialNumber: big.NewInt(1), NotBefore: now.Add(-time.Hour), NotAfter: now.Add(time.Hour), KeyUsage: x509.KeyUsageDigitalSignature}
	if client {
		cert.ExtKeyUsage = []x509.ExtKeyUsage{x509.ExtKeyUsageClientAuth}
	} else {
		cert.ExtKeyUsage = []x509.ExtKeyUsage{x509.ExtKeyUsageServerAuth}
		cert.IPAddresses = []net.IP{net.ParseIP("127.0.0.1")}
	}
	der, err := x509.CreateCertificate(rand.Reader, cert, cert, &key.PublicKey, key)
	if err != nil {
		t.Fatal(err)
	}
	leaf, err := x509.ParseCertificate(der)
	if err != nil {
		t.Fatal(err)
	}
	return tls.Certificate{Certificate: [][]byte{der}, PrivateKey: key, Leaf: leaf}
}
func keyOf(c tls.Certificate) string {
	key, _ := identity.PublicKeyFingerprint(c.Leaf.PublicKey)
	return key
}
func testManager(t *testing.T, storage *memoryStore) *Manager {
	t.Helper()
	m, err := New(storage, strings.Repeat("a", 64), nil)
	if err != nil {
		t.Fatal(err)
	}
	return m
}
func enrollment(t *testing.T, m *Manager, cert tls.Certificate, secret string) *httptest.ResponseRecorder {
	t.Helper()
	b, _ := json.Marshal(map[string]any{"version": 1, "secret": secret, "label": "Test phone"})
	r := httptest.NewRequest("POST", "https://192.168.1.2/pair", bytes.NewReader(b))
	r.TLS = &tls.ConnectionState{Version: tls.VersionTLS13, PeerCertificates: []*x509.Certificate{cert.Leaf}}
	w := httptest.NewRecorder()
	m.Enrollment(w, r)
	return w
}
func approve(t *testing.T, m *Manager, cert tls.Certificate) Invitation {
	t.Helper()
	i, err := m.Open("192.168.1.2", 9844)
	if err != nil {
		t.Fatal(err)
	}
	if w := enrollment(t, m, cert, i.Secret); w.Code != 200 {
		t.Fatal(w.Code)
	}
	if err := m.Approve(m.pending.ID); err != nil {
		t.Fatal(err)
	}
	return i
}

func TestEnrollmentApprovalSingleUseRecoveryAndRevocation(t *testing.T) {
	storage := &memoryStore{}
	m := testManager(t, storage)
	a, b := testCertificate(t, true), testCertificate(t, true)
	i, _ := m.Open("192.168.1.2", 9844)
	if w := enrollment(t, m, a, i.Secret); w.Code != 200 || !strings.Contains(w.Body.String(), "pending") || m.Allowed(keyOf(a)) {
		t.Fatal("invitation authorized without approval")
	}
	id := m.pending.ID
	if w := enrollment(t, m, b, i.Secret); w.Code != 409 {
		t.Fatal("simultaneous claim was accepted")
	}
	if err := m.Approve("stale"); err == nil {
		t.Fatal("stale approval")
	}
	if err := m.Approve(id); err != nil {
		t.Fatal(err)
	}
	if !m.Allowed(keyOf(a)) || m.Allowed(keyOf(b)) {
		t.Fatal("incorrect grant")
	}
	if bytes.Contains(storage.data, []byte(i.Secret)) {
		t.Fatal("raw enrollment secret persisted")
	}
	// Simulate a lost acknowledgment followed by host restart. Only the same
	// proven key can recover the durable receipt; another key cannot replay it.
	m = testManager(t, storage)
	if w := enrollment(t, m, a, i.Secret); w.Code != 200 || !strings.Contains(w.Body.String(), "approved") {
		t.Fatal("lost ack could not recover")
	}
	if w := enrollment(t, m, b, i.Secret); w.Code != 410 {
		t.Fatal("consumed invitation authorized another key")
	}
	if err := m.Revoke(keyOf(a)); err != nil {
		t.Fatal(err)
	}
	m = testManager(t, storage)
	if m.Allowed(keyOf(a)) || enrollment(t, m, a, i.Secret).Code != 410 {
		t.Fatal("revocation did not survive restart")
	}
}

func TestEnrollmentExpiryRejectionAndPersistenceFailure(t *testing.T) {
	storage := &memoryStore{}
	m := testManager(t, storage)
	a := testCertificate(t, true)
	now := time.Now()
	m.now = func() time.Time { return now }
	i, _ := m.Open("192.168.1.2", 9844)
	enrollment(t, m, a, i.Secret)
	id := m.pending.ID
	now = time.Unix(i.ExpiresAt, 0)
	if m.Approve(id) == nil || enrollment(t, m, a, i.Secret).Code != 410 {
		t.Fatal("expiry boundary accepted")
	}
	i, _ = m.Open("192.168.1.2", 9844)
	enrollment(t, m, a, i.Secret)
	if err := m.Reject(m.pending.ID); err != nil {
		t.Fatal(err)
	}
	if enrollment(t, m, a, i.Secret).Code != 410 {
		t.Fatal("rejection did not burn window")
	}
	i, _ = m.Open("192.168.1.2", 9844)
	enrollment(t, m, a, i.Secret)
	storage.fail = true
	if m.Approve(m.pending.ID) == nil || m.Allowed(keyOf(a)) || storage.data != nil {
		t.Fatal("failed persistence granted playback")
	}
	if enrollment(t, m, a, i.Secret).Code != 503 {
		t.Fatal("failed store did not close authorization")
	}
}

func TestStateFailsClosed(t *testing.T) {
	storage := &memoryStore{}
	m := testManager(t, storage)
	approve(t, m, testCertificate(t, true))
	valid := append([]byte(nil), storage.data...)
	for _, invalid := range [][]byte{nil, {}, []byte(`{"version":2}`), append(valid, 'x'), bytes.Replace(valid, []byte(`"version":1`), []byte(`"version":1,"version":1`), 1), bytes.Replace(valid, []byte(strings.Repeat("a", 64)), []byte(strings.Repeat("b", 64)), 1)} {
		if invalid == nil {
			invalid = []byte{}
		}
		if _, err := New(&memoryStore{data: invalid}, strings.Repeat("a", 64), nil); err == nil {
			t.Fatal("corrupt state accepted")
		}
	}
	storage.fail = true
	key := m.Devices()[0].Fingerprint
	if m.Revoke(key) == nil || m.Allowed(key) {
		t.Fatal("failed revoke must disable live authorization")
	}
}

type mediaPeer struct{ closed atomic.Bool }

func (*mediaPeer) Offer() (string, error) { return "offer", nil }
func (*mediaPeer) Answer(string) error    { return nil }
func (*mediaPeer) Status() (rtc.Status, error) {
	return rtc.Status{State: "connected", Opus: true}, nil
}
func (p *mediaPeer) Close() { p.closed.Store(true) }

func TestMutualTLSStreamBindingRevocationAndRestart(t *testing.T) {
	storage := &memoryStore{}
	m := testManager(t, storage)
	a, b, unknown := testCertificate(t, true), testCertificate(t, true), testCertificate(t, true)
	approve(t, m, a)
	approve(t, m, b)
	var allocations atomic.Int32
	peer := &mediaPeer{}
	host, err := session.NewPairedHost(m, func(time.Time, session.OfferOptions) (session.Resources, error) {
		allocations.Add(1)
		return session.Resources{Peer: peer}, nil
	})
	if err != nil {
		t.Fatal(err)
	}
	defer host.Close("test_complete")
	serverCert := testCertificate(t, false)
	server := httptest.NewUnstartedServer(host)
	server.TLS = m.TLSConfig(func(*tls.ClientHelloInfo) (*tls.Certificate, error) { return &serverCert, nil })
	server.TLS.Certificates = []tls.Certificate{serverCert} // Prevent httptest installing its unrelated default certificate.
	server.StartTLS()
	defer server.Close()
	client := func(cert *tls.Certificate) *http.Client {
		roots := x509.NewCertPool()
		roots.AddCert(serverCert.Leaf)
		config := &tls.Config{MinVersion: tls.VersionTLS13, RootCAs: roots}
		if cert != nil {
			config.Certificates = []tls.Certificate{*cert}
		}
		transport := &http.Transport{TLSClientConfig: config}
		t.Cleanup(transport.CloseIdleConnections)
		return &http.Client{Transport: transport, Timeout: 2 * time.Second}
	}
	call := func(c *http.Client, path, token, body string) (int, string) {
		t.Helper()
		r, _ := http.NewRequest("POST", server.URL+path, strings.NewReader(body))
		if token != "" {
			r.Header.Set("Authorization", "Bearer "+token)
		}
		response, err := c.Do(r)
		if err != nil {
			return 0, ""
		}
		defer response.Body.Close()
		data, _ := io.ReadAll(response.Body)
		return response.StatusCode, string(data)
	}
	if code, _ := call(client(nil), "/offer", "", `{"version":3}`); code != 0 {
		t.Fatal("missing certificate completed TLS")
	}
	if code, _ := call(client(&unknown), "/offer", "", `{"version":3}`); code != 403 {
		t.Fatal("unknown key accepted", code)
	}
	if allocations.Load() != 0 {
		t.Fatal("unauthorized request allocated media")
	}
	ca, cb := client(&a), client(&b)
	if code, _ := call(ca, "/offer", strings.Repeat("x", 43), `{"version":2}`); code != 401 {
		t.Fatal("legacy downgrade accepted", code)
	}
	code, body := call(ca, "/offer", "", `{"version":3}`)
	var offer struct {
		Version int
		Session string
	}
	json.Unmarshal([]byte(body), &offer)
	if code != 200 || offer.Version != 3 || len(offer.Session) != 43 {
		t.Fatal("paired offer failed", code)
	}
	if code, _ := call(cb, "/answer", offer.Session, `{"version":3,"sdp":"answer"}`); code != 403 {
		t.Fatal("cross-client credential accepted", code)
	}
	if code, _ := call(ca, "/answer", offer.Session, `{"version":3,"sdp":"answer"}`); code != 200 {
		t.Fatal("owner answer failed", code)
	}
	if code, _ := call(cb, "/stop", offer.Session, `{"reason":"user_stop"}`); code != 403 {
		t.Fatal("cross-client stop accepted", code)
	}
	if err := m.Revoke(keyOf(a)); err != nil {
		t.Fatal(err)
	}
	host.Revoke(keyOf(a))
	if code, _ := call(ca, "/status", offer.Session, ""); code != 403 {
		t.Fatal("reused TLS connection bypassed revocation", code)
	}
	deadline := time.Now().Add(time.Second)
	for !peer.closed.Load() && time.Now().Before(deadline) {
		time.Sleep(time.Millisecond)
	}
	if !peer.closed.Load() {
		t.Fatal("revocation left media alive")
	}
	// Reload grants while the TLS transport is still alive; authorization is
	// application state, never cached in an HTTP connection or bearer token.
	reopened := testManager(t, storage)
	if reopened.Allowed(keyOf(a)) || !reopened.Allowed(keyOf(b)) {
		t.Fatal("restart lost current grants")
	}
}

func TestClientCertificateValidation(t *testing.T) {
	valid := testCertificate(t, true)
	now := time.Now()
	cs := tls.ConnectionState{Version: tls.VersionTLS13, PeerCertificates: []*x509.Certificate{valid.Leaf}}
	if _, err := ClientKey(&cs, now); err != nil {
		t.Fatal(err)
	}
	for _, mutate := range []func(*tls.ConnectionState){
		func(s *tls.ConnectionState) { s.Version = tls.VersionTLS12 },
		func(s *tls.ConnectionState) { s.PeerCertificates = nil },
		func(s *tls.ConnectionState) { s.PeerCertificates = append(s.PeerCertificates, s.PeerCertificates[0]) },
		func(s *tls.ConnectionState) { s.PeerCertificates[0].NotAfter = now },
		func(s *tls.ConnectionState) { s.PeerCertificates[0].NotBefore = now.Add(time.Hour) },
		func(s *tls.ConnectionState) {
			s.PeerCertificates[0].ExtKeyUsage = []x509.ExtKeyUsage{x509.ExtKeyUsageServerAuth}
		},
		func(s *tls.ConnectionState) { s.PeerCertificates[0].Signature = []byte("invalid") },
	} {
		copyCert := *valid.Leaf
		copyState := tls.ConnectionState{Version: tls.VersionTLS13, PeerCertificates: []*x509.Certificate{&copyCert}}
		mutate(&copyState)
		if _, err := ClientKey(&copyState, now); err == nil {
			t.Fatal("invalid certificate accepted")
		}
	}
}
