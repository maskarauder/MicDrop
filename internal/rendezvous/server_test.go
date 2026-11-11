package rendezvous

import (
	"bytes"
	"context"
	"crypto/ecdsa"
	"crypto/elliptic"
	"crypto/hmac"
	"crypto/rand"
	"crypto/sha1"
	"crypto/tls"
	"crypto/x509"
	"encoding/base64"
	"encoding/json"
	"errors"
	"io"
	"log"
	"math/big"
	"net"
	"net/http"
	"net/http/httptest"
	"strconv"
	"strings"
	"sync"
	"sync/atomic"
	"testing"
	"time"

	"github.com/coder/websocket"
	"github.com/maskarauder/MicDrop/internal/identity"
	"github.com/maskarauder/MicDrop/internal/pairing"
)

func timeFixture() time.Time { return time.Date(2026, 10, 9, 0, 0, 0, 0, time.UTC) }
func testService(t *testing.T, c Config, edit func(*Server)) (*Server, *httptest.Server) {
	t.Helper()
	s, err := New(c)
	if err != nil {
		t.Fatal(err)
	}
	if edit != nil {
		edit(s)
	}
	h := httptest.NewUnstartedServer(s)
	h.Config.ErrorLog = log.New(io.Discard, "", 0)
	h.TLS = &tls.Config{MinVersion: tls.VersionTLS13}
	h.StartTLS()
	t.Cleanup(func() { s.Close(); h.Close() })
	return s, h
}
func rawDial(t *testing.T, h *httptest.Server, token string) *websocket.Conn {
	t.Helper()
	ctx, cancel := context.WithTimeout(context.Background(), 3*time.Second)
	defer cancel()
	c, _, err := websocket.Dial(ctx, h.URL+"/v1/tunnel", &websocket.DialOptions{HTTPClient: h.Client(), HTTPHeader: http.Header{"Authorization": []string{"Bearer " + token}}, Subprotocols: []string{Subprotocol}})
	if err != nil {
		t.Fatal(err)
	}
	c.SetReadLimit(MaxFrameBytes)
	t.Cleanup(func() { c.CloseNow() })
	return c
}
func ready(t *testing.T, c *websocket.Conn) {
	t.Helper()
	ctx, cancel := context.WithTimeout(context.Background(), 2*time.Second)
	defer cancel()
	typ, b, err := c.Read(ctx)
	if err != nil || typ != websocket.MessageText || string(b) != Ready {
		t.Fatalf("missing ready: %v", err)
	}
}
func closed(t *testing.T, c *websocket.Conn) {
	t.Helper()
	ctx, cancel := context.WithTimeout(context.Background(), 2*time.Second)
	defer cancel()
	if _, _, err := c.Read(ctx); err == nil || errors.Is(err, context.DeadlineExceeded) {
		t.Fatalf("socket did not close: %v", err)
	}
}
func request(t *testing.T, h *httptest.Server, path, token string) *http.Response {
	t.Helper()
	r, _ := http.NewRequest(http.MethodGet, h.URL+path, nil)
	r.Header.Set("Authorization", "Bearer "+token)
	resp, err := h.Client().Do(r)
	if err != nil {
		t.Fatal(err)
	}
	return resp
}
func awaitEmpty(t *testing.T, s *Server) {
	t.Helper()
	deadline := time.After(3 * time.Second)
	tick := time.NewTicker(time.Millisecond)
	defer tick.Stop()
	for {
		s.mu.Lock()
		n := 0
		for _, p := range s.principals {
			n += p.route.count[p.role]
		}
		s.mu.Unlock()
		if n == 0 {
			return
		}
		select {
		case <-deadline:
			t.Fatal("tunnel reservations leaked")
		case <-tick.C:
		}
	}
}

func TestRelayDuplexCloseAndReuse(t *testing.T) {
	c := testConfig()
	s, h := testService(t, c, nil)
	for range 3 {
		host := rawDial(t, h, c.Routes[0].HostToken)
		client := rawDial(t, h, c.Routes[0].ClientToken)
		ready(t, host)
		ready(t, client)
		for _, pair := range [][2]*websocket.Conn{{host, client}, {client, host}} {
			ctx, cancel := context.WithTimeout(context.Background(), time.Second)
			payload := bytes.Repeat([]byte{0, 7, 255, 42}, 8192)
			if err := pair[0].Write(ctx, websocket.MessageBinary, payload); err != nil {
				t.Fatal(err)
			}
			typ, b, err := pair[1].Read(ctx)
			cancel()
			if err != nil || typ != websocket.MessageBinary || !bytes.Equal(payload, b) {
				t.Fatalf("relay altered bytes: %v", err)
			}
		}
		client.CloseNow()
		closed(t, host)
		awaitEmpty(t, s)
	}
}

func TestTokensCannotCrossRoutesAndWaitIsBounded(t *testing.T) {
	c := testConfig()
	other := testConfig().Routes[0]
	other.ID = "other"
	c.Routes = append(c.Routes, other)
	s, h := testService(t, c, func(s *Server) { s.waitTimeout = 500 * time.Millisecond })
	a := rawDial(t, h, c.Routes[0].HostToken)
	b := rawDial(t, h, c.Routes[1].ClientToken)
	closed(t, a)
	closed(t, b)
	awaitEmpty(t, s)
}

func TestCapacityAndShutdownReleasePendingConnections(t *testing.T) {
	c := testConfig()
	s, h := testService(t, c, nil)
	var conns []*websocket.Conn
	for range MaxConnectionsPerRole {
		conns = append(conns, rawDial(t, h, c.Routes[0].HostToken))
	}
	ctx, cancel := context.WithTimeout(context.Background(), time.Second)
	defer cancel()
	_, resp, err := websocket.Dial(ctx, h.URL+"/v1/tunnel", &websocket.DialOptions{HTTPClient: h.Client(), HTTPHeader: http.Header{"Authorization": []string{"Bearer " + c.Routes[0].HostToken}}, Subprotocols: []string{Subprotocol}})
	if err == nil || resp.StatusCode != http.StatusServiceUnavailable {
		t.Fatal("capacity not enforced")
	}
	s.Close()
	for _, conn := range conns {
		closed(t, conn)
	}
	awaitEmpty(t, s)
}

func TestInvalidFramesAndIdleConnectionsCloseBothSides(t *testing.T) {
	for _, test := range []string{"text", "large", "empty", "idle"} {
		t.Run(test, func(t *testing.T) {
			c := testConfig()
			s, h := testService(t, c, func(s *Server) {
				if test == "idle" {
					s.idleTimeout = 500 * time.Millisecond
				}
			})
			a := rawDial(t, h, c.Routes[0].HostToken)
			b := rawDial(t, h, c.Routes[0].ClientToken)
			ready(t, a)
			ready(t, b)
			ctx, cancel := context.WithTimeout(context.Background(), time.Second)
			defer cancel()
			switch test {
			case "text":
				_ = a.Write(ctx, websocket.MessageText, []byte("bad"))
			case "large":
				_ = a.Write(ctx, websocket.MessageBinary, make([]byte, MaxFrameBytes+1))
			case "empty":
				_ = a.Write(ctx, websocket.MessageBinary, nil)
			}
			closed(t, b)
			awaitEmpty(t, s)
		})
	}
}

func TestCredentialIssuanceExpiryAndRateLimits(t *testing.T) {
	c := testConfig()
	c.STUNURLs = []string{"stun:relay.example:3478"}
	c.TURN = &TURNConfig{URLs: []string{"turn:relay.example:3478?transport=udp"}, SharedSecret: NewToken()}
	_, h := testService(t, c, func(s *Server) { s.now = timeFixture })
	var previous string
	for range 2 {
		resp := request(t, h, "/v1/ice", c.Routes[0].ClientToken)
		b, _ := io.ReadAll(resp.Body)
		resp.Body.Close()
		if resp.StatusCode != 200 || resp.Header.Get("Cache-Control") != "no-store" {
			t.Fatal("ICE response not private")
		}
		var ice ICEConfiguration
		if json.Unmarshal(b, &ice) != nil || ice.Version != 1 || len(ice.Servers) != 2 || ice.ExpiresAt != timeFixture().Add(CredentialLifetime).Unix() {
			t.Fatal("incorrect ICE response")
		}
		turn := ice.Servers[1]
		mac := hmac.New(sha1.New, []byte(c.TURN.SharedSecret))
		_, _ = mac.Write([]byte(turn.Username))
		if turn.Credential != base64.StdEncoding.EncodeToString(mac.Sum(nil)) || !strings.HasPrefix(turn.Username, strconv.FormatInt(ice.ExpiresAt, 10)+":") || turn.Username == previous {
			t.Fatal("invalid TURN REST credentials")
		}
		previous = turn.Username
		for _, secret := range []string{c.TURN.SharedSecret, c.Routes[0].HostToken, c.Routes[0].ClientToken} {
			if bytes.Contains(b, []byte(secret)) {
				t.Fatal("secret disclosed")
			}
		}
	}
	resp := request(t, h, "/v1/ice", c.Routes[0].ClientToken)
	defer resp.Body.Close()
	if resp.StatusCode != 429 {
		t.Fatal("credential issuance is unlimited")
	}
}

func TestRequestPolicyAndAuthentication(t *testing.T) {
	c := testConfig()
	s, h := testService(t, c, nil)
	for _, tc := range []struct {
		path, token string
		code        int
	}{{"/v1/ice", "wrong", 401}, {"/v1/ice?token=secret", c.Routes[0].HostToken, 400}, {"/v1/ice", c.Routes[0].HostToken, 200}, {"/v1/tunnel", c.Routes[0].HostToken, 400}} {
		resp := request(t, h, tc.path, tc.token)
		resp.Body.Close()
		if resp.StatusCode != tc.code {
			t.Fatalf("unexpected policy response: %d", resp.StatusCode)
		}
	}
	for _, header := range []string{"Origin", "Authorization"} {
		r, _ := http.NewRequest("GET", h.URL+"/v1/ice", nil)
		r.Header.Set("Authorization", "Bearer "+c.Routes[0].HostToken)
		r.Header.Add(header, "untrusted")
		resp, err := h.Client().Do(r)
		if err != nil {
			t.Fatal(err)
		}
		resp.Body.Close()
		if resp.StatusCode == 200 {
			t.Fatal("accepted ambiguous/browser request")
		}
	}
	w := httptest.NewRecorder()
	s.ServeHTTP(w, httptest.NewRequest("GET", "/v1/ice", nil))
	if w.Code != 426 {
		t.Fatal("accepted plaintext")
	}
	if _, err := Dial(context.Background(), "http://localhost", c.Routes[0].HostToken, nil); err == nil {
		t.Fatal("client accepted plaintext")
	}
}

func TestByteRateLimitAndAbsoluteLifetime(t *testing.T) {
	for _, mode := range []string{"byte rate", "lifetime"} {
		t.Run(mode, func(t *testing.T) {
			c := testConfig()
			s, h := testService(t, c, func(s *Server) {
				if mode == "lifetime" {
					s.lifetime = 500 * time.Millisecond
				} else {
					s.now = timeFixture
				}
			})
			a := rawDial(t, h, c.Routes[0].HostToken)
			b := rawDial(t, h, c.Routes[0].ClientToken)
			ready(t, a)
			ready(t, b)
			if mode == "byte rate" {
				ctx, cancel := context.WithTimeout(context.Background(), 2*time.Second)
				defer cancel()
				for range 4 {
					if err := a.Write(ctx, websocket.MessageBinary, make([]byte, MaxFrameBytes)); err != nil {
						t.Fatal(err)
					}
					if _, _, err := b.Read(ctx); err != nil {
						t.Fatal(err)
					}
				}
				_ = a.Write(ctx, websocket.MessageBinary, []byte{1})
			}
			closed(t, b)
			awaitEmpty(t, s)
		})
	}
}

func TestDialRejectsRedirectAndUntrustedOuterTLS(t *testing.T) {
	var calls atomic.Int32
	target := httptest.NewTLSServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) { calls.Add(1) }))
	defer target.Close()
	redirect := httptest.NewTLSServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		http.Redirect(w, r, target.URL, http.StatusTemporaryRedirect)
	}))
	defer redirect.Close()
	ctx, cancel := context.WithTimeout(context.Background(), 2*time.Second)
	defer cancel()
	if _, err := Dial(ctx, redirect.URL, NewToken(), redirect.Client()); err == nil || calls.Load() != 0 {
		t.Fatal("followed rendezvous redirect")
	}
	c := testConfig()
	_, h := testService(t, c, nil)
	if conn, err := Dial(ctx, h.URL, c.Routes[0].HostToken, nil); err == nil {
		conn.Close()
		t.Fatal("accepted an untrusted rendezvous certificate")
	}
}

func TestPendingDialCancellationAndActiveShutdown(t *testing.T) {
	c := testConfig()
	s, h := testService(t, c, nil)
	ctx, cancel := context.WithTimeout(context.Background(), 500*time.Millisecond)
	defer cancel()
	if conn, err := Dial(ctx, h.URL, c.Routes[0].HostToken, h.Client()); err == nil {
		conn.Close()
		t.Fatal("unpaired dial ignored cancellation")
	}
	awaitEmpty(t, s)
	a := rawDial(t, h, c.Routes[0].HostToken)
	b := rawDial(t, h, c.Routes[0].ClientToken)
	ready(t, a)
	ready(t, b)
	s.Close()
	closed(t, a)
	closed(t, b)
	awaitEmpty(t, s)
}

func cert(t *testing.T) tls.Certificate {
	t.Helper()
	key, err := ecdsa.GenerateKey(elliptic.P256(), rand.Reader)
	if err != nil {
		t.Fatal(err)
	}
	template := &x509.Certificate{SerialNumber: big.NewInt(1), NotBefore: time.Now().Add(-time.Hour), NotAfter: time.Now().Add(time.Hour), DNSNames: []string{"paired.test"}, KeyUsage: x509.KeyUsageDigitalSignature | x509.KeyUsageCertSign, ExtKeyUsage: []x509.ExtKeyUsage{x509.ExtKeyUsageServerAuth, x509.ExtKeyUsageClientAuth}, IsCA: true, BasicConstraintsValid: true}
	der, err := x509.CreateCertificate(rand.Reader, template, template, &key.PublicKey, key)
	if err != nil {
		t.Fatal(err)
	}
	leaf, _ := x509.ParseCertificate(der)
	return tls.Certificate{Certificate: [][]byte{der}, PrivateKey: key, Leaf: leaf}
}
func streams(t *testing.T, h *httptest.Server, c Config) (net.Conn, net.Conn) {
	t.Helper()
	ctx, cancel := context.WithCancel(context.Background())
	t.Cleanup(cancel)
	var a, b net.Conn
	var ea, eb error
	var wg sync.WaitGroup
	wg.Add(2)
	go func() { defer wg.Done(); a, ea = Dial(ctx, h.URL, c.Routes[0].HostToken, h.Client()) }()
	go func() { defer wg.Done(); b, eb = Dial(ctx, h.URL, c.Routes[0].ClientToken, h.Client()) }()
	wg.Wait()
	if ea != nil || eb != nil {
		t.Fatalf("tunnel dial failed: %v / %v", ea, eb)
	}
	t.Cleanup(func() { a.Close(); b.Close() })
	return a, b
}

func TestPairedTLSAcrossUntrustedRelay(t *testing.T) {
	for _, mode := range []string{"paired", "substituted host", "unapproved phone"} {
		t.Run(mode, func(t *testing.T) {
			c := testConfig()
			_, h := testService(t, c, nil)
			a, b := streams(t, h, c)
			host, phone := cert(t), cert(t)
			expectedPhone, _ := identity.PublicKeyFingerprint(phone.Leaf.PublicKey)
			roots := x509.NewCertPool()
			roots.AddCert(host.Leaf)
			if mode == "substituted host" {
				host = cert(t)
			}
			if mode == "unapproved phone" {
				phone = cert(t)
			}
			server := tls.Server(a, &tls.Config{MinVersion: tls.VersionTLS13, MaxVersion: tls.VersionTLS13, Certificates: []tls.Certificate{host}, ClientAuth: tls.RequireAnyClientCert, VerifyConnection: func(cs tls.ConnectionState) error {
				key, err := pairing.ClientKey(&cs, time.Now())
				if err != nil || key != expectedPhone {
					return errors.New("unapproved peer")
				}
				return nil
			}})
			client := tls.Client(b, &tls.Config{MinVersion: tls.VersionTLS13, RootCAs: roots, ServerName: "paired.test", Certificates: []tls.Certificate{phone}})
			deadline := time.Now().Add(2 * time.Second)
			server.SetDeadline(deadline)
			client.SetDeadline(deadline)
			done := make(chan error, 1)
			go func() {
				err := server.Handshake()
				if err == nil {
					_, err = server.Write([]byte("authenticated SDP"))
				}
				done <- err
			}()
			payload, err := io.ReadAll(io.LimitReader(client, 17))
			serverErr := <-done
			if mode == "paired" {
				if err != nil || serverErr != nil || string(payload) != "authenticated SDP" {
					t.Fatalf("paired TLS failed: %v / %v", err, serverErr)
				}
			} else if err == nil && serverErr == nil {
				t.Fatal("relay substituted an authenticated peer")
			}
		})
	}
}
