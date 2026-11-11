package rendezvous

import (
	"bufio"
	"context"
	"crypto/sha256"
	"crypto/tls"
	"crypto/x509"
	"encoding/base64"
	"encoding/json"
	"errors"
	"io"
	"net"
	"net/http"
	"strings"
	"testing"
	"time"
)

func remoteFixture(c Config, url string) RemoteConfig {
	return RemoteConfig{Version: 1, URL: url, HostToken: c.Routes[0].HostToken, ClientToken: c.Routes[0].ClientToken}
}
func TestRemoteConfigurationAndInvitation(t *testing.T) {
	c := remoteFixture(testConfig(), "https://relay.example.test:8443")
	b, _ := json.Marshal(c)
	if _, err := DecodeRemote(strings.NewReader(string(b))); err != nil {
		t.Fatal(err)
	}
	for _, endpoint := range []string{"http://relay.test", "https://user@relay.test", "https://relay.test/a", "https://relay.test?token=x", "https://relay.test#x", "https:///", "https://relay.test:0", "https://relay.test:65536"} {
		bad := c
		bad.URL = endpoint
		if bad.Validate() == nil {
			t.Fatalf("accepted %s", endpoint)
		}
	}
	for _, text := range []string{string(b) + " {}", strings.Repeat(" ", 4097), `{"version":1,"unknown":"secret"}`} {
		if _, err := DecodeRemote(strings.NewReader(text)); err == nil {
			t.Fatal("accepted malformed configuration")
		}
	}
	link := c.Invitation("micdrop://pair/v1/example")
	decoded, err := base64.RawURLEncoding.DecodeString(strings.TrimPrefix(link, "micdrop://remote/v1/"))
	if err != nil || strings.Contains(string(decoded), c.HostToken) || !strings.Contains(string(decoded), c.ClientToken) {
		t.Fatal("wrong role exported")
	}
}

func TestICECacheUsesBoundedFreshCredentials(t *testing.T) {
	c := testConfig()
	c.STUNURLs = []string{"stun:relay.example.test:3478"}
	c.TURN = &TURNConfig{URLs: []string{"turn:relay.example.test:3478?transport=udp"}, SharedSecret: NewToken()}
	_, server := testService(t, c, nil)
	config := remoteFixture(c, server.URL)
	config.ForceRelay = true
	cache := NewICECache(config, server.Client())
	first, err := cache.Get(context.Background())
	if err != nil {
		t.Fatal(err)
	}
	for i := 0; i < 5; i++ {
		next, err := cache.Get(context.Background())
		if err != nil || next.Servers[1].Username != first.Servers[1].Username {
			t.Fatal("credentials not cached")
		}
	}
	first.ExpiresAt = time.Now().Add(20 * time.Second).Unix()
	if first.Validate(time.Now(), true) == nil {
		t.Fatal("accepted expiring credentials")
	}
	first.ExpiresAt = time.Now().Add(10 * time.Minute).Unix()
	first.Servers = nil
	if first.Validate(time.Now(), true) == nil {
		t.Fatal("forced relay silently allowed direct")
	}
	if first.Validate(time.Now(), false) != nil {
		t.Fatal("direct-only configuration rejected")
	}
	config.HostToken = NewToken()
	if _, err := NewICECache(config, server.Client()).Get(context.Background()); err == nil {
		t.Fatal("bad resource token accepted")
	}
	if _, err := NewICECache(remoteFixture(c, server.URL), nil).Get(context.Background()); err == nil {
		t.Fatal("untrusted outer TLS accepted")
	}
}

func TestOutboundListenerServesRepeatedPairedHTTPAndCancelsIdleAccept(t *testing.T) {
	c := testConfig()
	service, relay := testService(t, c, nil)
	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()
	listener, err := Listen(ctx, remoteFixture(c, relay.URL), relay.Client())
	if err != nil {
		t.Fatal(err)
	}
	host, phone := cert(t), cert(t)
	roots := x509.NewCertPool()
	roots.AddCert(host.Leaf)
	config := &tls.Config{MinVersion: tls.VersionTLS13, Certificates: []tls.Certificate{host}, ClientAuth: tls.RequireAnyClientCert}
	server := &http.Server{Handler: http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if len(r.TLS.PeerCertificates) != 1 || !r.TLS.PeerCertificates[0].Equal(phone.Leaf) {
			http.Error(w, "Forbidden", 403)
			return
		}
		w.Header().Set("Content-Type", "application/json")
		io.WriteString(w, `{"ok":true}`)
	}), ReadHeaderTimeout: time.Second}
	done := make(chan error, 1)
	go func() { done <- server.Serve(tls.NewListener(listener, config)) }()
	defer server.Close()
	for i := 0; i < 3; i++ {
		raw, err := Dial(ctx, relay.URL, c.Routes[0].ClientToken, relay.Client())
		if err != nil {
			t.Fatal(err)
		}
		client := tls.Client(raw, &tls.Config{MinVersion: tls.VersionTLS13, RootCAs: roots, ServerName: "paired.test", Certificates: []tls.Certificate{phone}})
		client.SetDeadline(time.Now().Add(3 * time.Second))
		if _, err = io.WriteString(client, "GET /status HTTP/1.0\r\nHost: paired.test\r\nConnection: close\r\n\r\n"); err != nil {
			t.Fatal(err)
		}
		response, err := http.ReadResponse(bufio.NewReader(client), nil)
		if err != nil {
			t.Fatal(err)
		}
		body, err := io.ReadAll(response.Body)
		response.Body.Close()
		client.Close()
		if err != nil || response.StatusCode != 200 || string(body) != `{"ok":true}` {
			t.Fatal("paired response failed")
		}
	}
	listener.Close()
	select {
	case err := <-done:
		if !errors.Is(err, net.ErrClosed) && !errors.Is(err, http.ErrServerClosed) {
			t.Fatal(err)
		}
	case <-time.After(time.Second):
		t.Fatal("idle accept stuck")
	}
	awaitEmpty(t, service)
}

func TestICECacheTransportFailureAllowsFastRetryWithinRecoveryWindow(t *testing.T) {
	c := testConfig()
	c.STUNURLs = []string{"stun:relay.example.test:3478"}
	_, server := testService(t, c, nil)
	now := time.Now()
	failTransport := true
	base := server.Client().Transport
	client := &http.Client{Transport: roundTripperFunc(func(r *http.Request) (*http.Response, error) {
		if failTransport {
			return nil, errors.New("network unreachable")
		}
		return base.RoundTrip(r)
	})}
	cache := NewICECache(remoteFixture(c, server.URL), client)
	cache.now = func() time.Time { return now }
	if _, err := cache.Get(context.Background()); err == nil {
		t.Fatal("expected initial transport error")
	}
	failTransport = false
	now = now.Add(2 * time.Second)
	if _, err := cache.Get(context.Background()); err == nil {
		t.Fatal("expected short cooldown to suppress immediate hammer")
	}
	now = now.Add(2 * time.Second) // 4s total (< 30s)
	if _, err := cache.Get(context.Background()); err != nil {
		t.Fatalf("transport failure locked out ICE fetch for 30s: %v", err)
	}
}

func TestOutboundListenerRedialsImmediatelyAfterNormalPollExpiration(t *testing.T) {
	c := testConfig()
	service, relay := testService(t, c, func(s *Server) {
		s.waitTimeout = 40 * time.Millisecond
		s.principals = map[[32]byte]*principal{}
		state := &routeState{}
		for role, token := range []string{c.Routes[0].HostToken, c.Routes[0].ClientToken} {
			servicePrincipal := &principal{route: state, role: role, requests: newBucket(100, 100), ice: newBucket(2, 1.0/30)}
			s.principals[sha256.Sum256([]byte(token))] = servicePrincipal
		}
	})
	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()
	listener, err := Listen(ctx, remoteFixture(c, relay.URL), relay.Client())
	if err != nil {
		t.Fatal(err)
	}
	listener.(*remoteListener).minPollWait = 20 * time.Millisecond

	accepted := make(chan net.Conn, 1)
	go func() {
		conn, acceptErr := listener.Accept()
		if acceptErr == nil {
			accepted <- conn
		}
	}()
	// Let multiple unmatched poll windows expire; exponential backoff would sleep >=1s+2s+4s.
	time.Sleep(180 * time.Millisecond)
	dialStarted := time.Now()
	clientConn, err := Dial(ctx, relay.URL, c.Routes[0].ClientToken, relay.Client())
	if err != nil {
		t.Fatal(err)
	}
	defer clientConn.Close()
	if time.Since(dialStarted) > 750*time.Millisecond {
		t.Fatalf("unmatched polls accumulated exponential backoff (%v)", time.Since(dialStarted))
	}
	select {
	case hostConn := <-accepted:
		hostConn.Close()
	case <-time.After(time.Second):
		t.Fatal("host did not accept matched tunnel")
	}
	listener.Close()
	awaitEmpty(t, service)
}

type roundTripperFunc func(*http.Request) (*http.Response, error)

func (f roundTripperFunc) RoundTrip(r *http.Request) (*http.Response, error) { return f(r) }
