package main

import (
	"bytes"
	"context"
	"crypto/ecdsa"
	"crypto/elliptic"
	"crypto/rand"
	"crypto/tls"
	"crypto/x509"
	"encoding/pem"
	"io"
	"math/big"
	"net"
	"os"
	"path/filepath"
	"strings"
	"sync"
	"testing"
	"time"

	"github.com/maskarauder/MicDrop/internal/rendezvous"
)

type certificateEvents struct {
	mu     sync.Mutex
	output bytes.Buffer
	events chan string
}

func (w *certificateEvents) Write(b []byte) (int, error) {
	w.mu.Lock()
	defer w.mu.Unlock()
	w.output.Write(b)
	select {
	case w.events <- string(b):
	default:
	}
	return len(b), nil
}

func TestServeAutomaticallyReloadsAndSanitizesFailures(t *testing.T) {
	now := time.Now()
	first := makeCertificate(t, 1, "rendezvous.test", now.Add(-time.Hour), now.Add(time.Hour))
	next := makeCertificate(t, 2, "rendezvous.test", now.Add(-time.Hour), now.Add(2*time.Hour))
	root := t.TempDir()
	certFile, keyFile, config := filepath.Join(root, "cert"), filepath.Join(root, "key"), filepath.Join(root, "config")
	writeCertificateFile(t, certFile, first.cert)
	writeCertificateFile(t, keyFile, first.key)
	if err := writePrivateConfig(config, rendezvous.Config{Version: 1, Routes: []rendezvous.Route{
		{ID: "test", HostToken: rendezvous.NewToken(), ClientToken: rendezvous.NewToken()},
	}}); err != nil {
		t.Fatal(err)
	}
	var check bytes.Buffer
	if run(context.Background(), []string{"check", "--config", config, "--tls-cert", certFile,
		"--tls-key", keyFile, "--tls-name", "rendezvous.test"}, &check, &check) != 0 {
		t.Fatal(check.String())
	}
	if run(context.Background(), []string{"check", "--config", config, "--tls-cert", certFile,
		"--tls-key", keyFile, "--tls-name", "wrong.test"}, &check, &check) == 0 {
		t.Fatal("wrong certificate hostname accepted")
	}
	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()
	w := &certificateEvents{events: make(chan string, 16)}
	done := make(chan int, 1)
	go func() {
		done <- run(ctx, []string{"serve", "--config", config, "--listen", "127.0.0.1:0",
			"--tls-cert", certFile, "--tls-key", keyFile, "--tls-name", "rendezvous.test", "--tls-reload-interval", "1s"}, w, w)
	}()
	wait := func(want string) {
		t.Helper()
		deadline := time.NewTimer(5 * time.Second)
		defer deadline.Stop()
		for {
			select {
			case message := <-w.events:
				if strings.Contains(message, want) {
					return
				}
			case <-deadline.C:
				t.Fatalf("did not observe %s", want)
			}
		}
	}
	wait("is running")
	writeCertificateFile(t, keyFile, []byte("do-not-log-private-fixture"))
	wait("reload failed")
	writeCertificateFile(t, certFile, next.cert)
	writeCertificateFile(t, keyFile, next.key)
	wait("certificate reloaded")
	cancel()
	select {
	case result := <-done:
		if result != 0 {
			t.Fatal("service did not stop cleanly")
		}
	case <-time.After(5 * time.Second):
		t.Fatal("service did not exit")
	}
	w.mu.Lock()
	defer w.mu.Unlock()
	if strings.Contains(w.output.String(), "do-not-log-private-fixture") || strings.Contains(w.output.String(), root) {
		t.Fatal("certificate failure exposed file contents or paths")
	}
}

type certificateFixture struct {
	cert, key []byte
	leaf      *x509.Certificate
}

func makeCertificate(t *testing.T, serial int64, name string, before, after time.Time) certificateFixture {
	t.Helper()
	key, err := ecdsa.GenerateKey(elliptic.P256(), rand.Reader)
	if err != nil {
		t.Fatal(err)
	}
	parent := &x509.Certificate{SerialNumber: big.NewInt(serial), DNSNames: []string{name},
		NotBefore: before, NotAfter: after, ExtKeyUsage: []x509.ExtKeyUsage{x509.ExtKeyUsageServerAuth},
		KeyUsage: x509.KeyUsageDigitalSignature}
	der, err := x509.CreateCertificate(rand.Reader, parent, parent, &key.PublicKey, key)
	if err != nil {
		t.Fatal(err)
	}
	private, err := x509.MarshalPKCS8PrivateKey(key)
	if err != nil {
		t.Fatal(err)
	}
	leaf, err := x509.ParseCertificate(der)
	if err != nil {
		t.Fatal(err)
	}
	return certificateFixture{pem.EncodeToMemory(&pem.Block{Type: "CERTIFICATE", Bytes: der}),
		pem.EncodeToMemory(&pem.Block{Type: "PRIVATE KEY", Bytes: private}), leaf}
}

func writeCertificateFile(t *testing.T, path string, data []byte) {
	t.Helper()
	if err := os.WriteFile(path, data, 0600); err != nil {
		t.Fatal(err)
	}
}

func TestCertificateRotationRetainsPairAndExistingTLSConnection(t *testing.T) {
	now := time.Now()
	first := makeCertificate(t, 1, "rendezvous.test", now.Add(-time.Hour), now.Add(time.Hour))
	next := makeCertificate(t, 2, "rendezvous.test", now.Add(-time.Hour), now.Add(2*time.Hour))
	root := t.TempDir()
	certFile, keyFile := filepath.Join(root, "cert.pem"), filepath.Join(root, "key.pem")
	writeCertificateFile(t, certFile, first.cert)
	writeCertificateFile(t, keyFile, first.key)
	r, err := newCertificateReloader(certFile, keyFile, "rendezvous.test")
	if err != nil {
		t.Fatal(err)
	}
	listener, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		t.Fatal(err)
	}
	secure := tls.NewListener(listener, &tls.Config{MinVersion: tls.VersionTLS13, GetCertificate: r.getCertificate})
	defer secure.Close()
	var workers sync.WaitGroup
	workers.Add(1)
	go func() {
		defer workers.Done()
		for {
			conn, err := secure.Accept()
			if err != nil {
				return
			}
			workers.Add(1)
			go func() {
				defer workers.Done()
				defer conn.Close()
				_ = conn.SetDeadline(time.Now().Add(5 * time.Second))
				_, _ = io.Copy(conn, conn)
			}()
		}
	}()
	defer func() { secure.Close(); workers.Wait() }()
	pool := x509.NewCertPool()
	pool.AddCert(first.leaf)
	pool.AddCert(next.leaf)
	dial := func(want int64) *tls.Conn {
		t.Helper()
		conn, err := tls.DialWithDialer(&net.Dialer{Timeout: time.Second}, "tcp", listener.Addr().String(),
			&tls.Config{RootCAs: pool, ServerName: "rendezvous.test", MinVersion: tls.VersionTLS13})
		if err != nil {
			t.Fatal(err)
		}
		if conn.ConnectionState().PeerCertificates[0].SerialNumber.Int64() != want {
			t.Fatal("wrong certificate served")
		}
		return conn
	}
	active := dial(1)
	defer active.Close()
	if changed, err := r.reload(now); err != nil || changed {
		t.Fatal("unchanged pair reported as renewed")
	}
	// Caddy replaces the files separately. Never publish half of the new pair.
	writeCertificateFile(t, certFile, next.cert)
	if _, err := r.reload(now); err == nil {
		t.Fatal("accepted mismatched files")
	}
	during := dial(1)
	during.Close()
	writeCertificateFile(t, keyFile, next.key)
	if changed, err := r.reload(now); err != nil || !changed {
		t.Fatal("valid renewal was not loaded", err)
	}
	after := dial(2)
	after.Close()
	if err := active.SetDeadline(time.Now().Add(time.Second)); err != nil {
		t.Fatal(err)
	}
	if _, err := active.Write([]byte("active tunnel")); err != nil {
		t.Fatal(err)
	}
	got := make([]byte, len("active tunnel"))
	if _, err := io.ReadFull(active, got); err != nil || string(got) != "active tunnel" {
		t.Fatal("rotation interrupted the existing connection", err)
	}
	if err := os.Remove(keyFile); err != nil {
		t.Fatal(err)
	}
	if _, err := r.reload(now); err == nil {
		t.Fatal("accepted missing key")
	}
	still := dial(2)
	still.Close()
}

func TestCertificateRejectsInvalidRenewalAndExpiredCache(t *testing.T) {
	now := time.Now()
	valid := makeCertificate(t, 1, "rendezvous.test", now.Add(-time.Hour), now.Add(time.Hour))
	root := t.TempDir()
	certFile, keyFile := filepath.Join(root, "cert.pem"), filepath.Join(root, "key.pem")
	writeCertificateFile(t, certFile, valid.cert)
	writeCertificateFile(t, keyFile, valid.key)
	r, err := newCertificateReloader(certFile, keyFile, "rendezvous.test")
	if err != nil {
		t.Fatal(err)
	}
	for _, fixture := range []certificateFixture{
		makeCertificate(t, 2, "rendezvous.test", now.Add(-2*time.Hour), now.Add(-time.Hour)),
		makeCertificate(t, 3, "rendezvous.test", now.Add(time.Hour), now.Add(2*time.Hour)),
		makeCertificate(t, 4, "wrong.test", now.Add(-time.Hour), now.Add(time.Hour)),
		{cert: []byte("broken certificate"), key: valid.key},
		{cert: bytes.Repeat([]byte{'x'}, certificateFileLimit+1), key: valid.key},
	} {
		writeCertificateFile(t, certFile, fixture.cert)
		writeCertificateFile(t, keyFile, fixture.key)
		if _, err := r.reload(now); err == nil {
			t.Fatal("accepted invalid renewal")
		}
		if r.current.Load().Leaf.SerialNumber.Int64() != 1 {
			t.Fatal("discarded last valid certificate")
		}
	}
	// Retaining the previous pair does not permit new TLS sessions past expiry.
	expired := makeCertificate(t, 5, "rendezvous.test", now.Add(-2*time.Hour), now.Add(-time.Hour))
	pair, err := tls.X509KeyPair(expired.cert, expired.key)
	if err != nil {
		t.Fatal(err)
	}
	pair.Leaf = expired.leaf
	r.current.Store(&pair)
	if _, err := r.getCertificate(nil); err == nil {
		t.Fatal("served expired cached certificate")
	}
	var empty certificateReloader
	if _, err := empty.getCertificate(nil); err == nil {
		t.Fatal("served uninitialized certificate")
	}
}

func TestCertificateReloadConcurrentWithHandshakes(t *testing.T) {
	now := time.Now()
	first := makeCertificate(t, 1, "rendezvous.test", now.Add(-time.Hour), now.Add(time.Hour))
	next := makeCertificate(t, 2, "rendezvous.test", now.Add(-time.Hour), now.Add(time.Hour))
	root := t.TempDir()
	certFile, keyFile := filepath.Join(root, "cert.pem"), filepath.Join(root, "key.pem")
	writeCertificateFile(t, certFile, first.cert)
	writeCertificateFile(t, keyFile, first.key)
	r, err := newCertificateReloader(certFile, keyFile, "rendezvous.test")
	if err != nil {
		t.Fatal(err)
	}
	var readers sync.WaitGroup
	for range 8 {
		readers.Add(1)
		go func() {
			defer readers.Done()
			for range 1000 {
				if cert, err := r.getCertificate(nil); err != nil || len(cert.Certificate) == 0 {
					t.Error("incomplete pair during reload")
				}
			}
		}()
	}
	for range 10 {
		for _, fixture := range []certificateFixture{next, first} {
			writeCertificateFile(t, certFile, fixture.cert)
			writeCertificateFile(t, keyFile, fixture.key)
			if _, err := r.reload(now); err != nil {
				t.Fatal(err)
			}
		}
	}
	readers.Wait()
}
