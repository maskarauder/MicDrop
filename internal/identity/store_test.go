package identity

import (
	"bytes"
	"crypto/aes"
	"crypto/cipher"
	"crypto/ecdsa"
	"crypto/elliptic"
	"crypto/rand"
	"crypto/tls"
	"crypto/x509"
	"encoding/hex"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"net"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"sync"
	"testing"
	"time"
)

// Portable storage contracts use a test-only protector. Production non-Windows
// code fails closed; Windows tests below exercise the actual DPAPI adapter.
type testProtection struct{ cipher.AEAD }

func protectionForTest(t *testing.T) testProtection {
	t.Helper()
	key := make([]byte, 32)
	if _, err := rand.Read(key); err != nil {
		t.Fatal(err)
	}
	block, err := aes.NewCipher(key)
	if err != nil {
		t.Fatal(err)
	}
	aead, err := cipher.NewGCM(block)
	if err != nil {
		t.Fatal(err)
	}
	return testProtection{aead}
}
func (p testProtection) protect(b []byte) ([]byte, error) {
	nonce := make([]byte, p.NonceSize())
	if _, err := rand.Read(nonce); err != nil {
		return nil, err
	}
	return p.Seal(nonce, nonce, b, nil), nil
}
func (p testProtection) unprotect(b []byte) ([]byte, error) {
	if len(b) < p.NonceSize() {
		return nil, errors.New("short test envelope")
	}
	return p.Open(nil, b[:p.NonceSize()], b[p.NonceSize():], nil)
}
func testStore(t *testing.T) *Store {
	t.Helper()
	return &Store{directory: filepath.Join(t.TempDir(), "identity"), protection: protectionForTest(t)}
}

func TestIdentityReloadAndSafePublicOutput(t *testing.T) {
	s := testStore(t)
	if _, err := s.Load(); !errors.Is(err, os.ErrNotExist) {
		t.Fatal(err)
	}
	first, created, err := s.Ensure()
	if err != nil || !created {
		t.Fatalf("init: %t %v", created, err)
	}
	before, _ := os.ReadFile(filepath.Join(s.directory, Filename))
	reopened := &Store{directory: s.directory, protection: s.protection}
	second, created, err := reopened.Ensure()
	if err != nil || created || first.Info() != second.Info() {
		t.Fatal("identity changed across reopen", err)
	}
	after, _ := os.ReadFile(filepath.Join(s.directory, Filename))
	if !bytes.Equal(before, after) {
		t.Fatal("idempotent init rewrote the protected file")
	}
	public, _ := json.Marshal(first)
	key, _ := x509.MarshalPKCS8PrivateKey(first.key)
	if bytes.Contains(before, key) || bytes.Contains(before, []byte("private_key")) ||
		bytes.Contains(public, []byte("private_key")) || bytes.Contains(public, []byte(first.key.D.Text(16))) {
		t.Fatal("private material exposed")
	}
	if fmt.Sprintf("%#v", first) != first.String() {
		t.Fatal("debug output bypassed redaction")
	}
}

func TestConcurrentFirstCreationPublishesOneCompleteIdentity(t *testing.T) {
	s := testStore(t)
	var group sync.WaitGroup
	type result struct {
		id      *Identity
		created bool
		err     error
	}
	results := make(chan result, 16)
	for range 16 {
		group.Add(1)
		go func() { defer group.Done(); id, created, err := s.Ensure(); results <- result{id, created, err} }()
	}
	group.Wait()
	close(results)
	var fingerprint string
	creations := 0
	for r := range results {
		if r.err != nil {
			t.Fatal(r.err)
		}
		if r.created {
			creations++
		}
		if fingerprint == "" {
			fingerprint = r.id.Info().Fingerprint
		}
		if fingerprint != r.id.Info().Fingerprint {
			t.Fatal("concurrent identities diverged")
		}
	}
	if creations != 1 {
		t.Fatalf("created %d identities", creations)
	}
	entries, err := os.ReadDir(s.directory)
	if err != nil || len(entries) != 1 || entries[0].Name() != Filename {
		t.Fatal("temporary files not cleaned", err)
	}
}

func TestInvalidOrForeignIdentityIsNeverOverwritten(t *testing.T) {
	for _, kind := range []string{"empty", "truncated", "oversized", "version", "tampered", "foreign", "directory"} {
		t.Run(kind, func(t *testing.T) {
			s := testStore(t)
			if _, _, err := s.Ensure(); err != nil {
				t.Fatal(err)
			}
			path := filepath.Join(s.directory, Filename)
			data, _ := os.ReadFile(path)
			switch kind {
			case "empty":
				data = nil
			case "truncated":
				data = data[:len(fileHeader)+1]
			case "oversized":
				data = make([]byte, maxFileBytes+1)
			case "version":
				data[4]++
			case "tampered":
				data[len(data)-1] ^= 1
			case "foreign":
				s.protection = protectionForTest(t)
			case "directory":
				if err := os.Remove(path); err != nil {
					t.Fatal(err)
				}
				if err := os.Mkdir(path, 0700); err != nil {
					t.Fatal(err)
				}
			}
			if kind != "directory" {
				if err := os.WriteFile(path, data, 0600); err != nil {
					t.Fatal(err)
				}
			}
			if _, created, err := s.Ensure(); created || !errors.Is(err, ErrInvalid) {
				t.Fatalf("bad file accepted/replaced: %t %v", created, err)
			}
			if kind != "directory" {
				after, _ := os.ReadFile(path)
				if !bytes.Equal(data, after) {
					t.Fatal("invalid file was overwritten")
				}
			}
		})
	}
}

func TestDecodedRecordRejectsUnexpectedFieldsTypesAndKeys(t *testing.T) {
	id, _ := generate(time.Now())
	der, _ := x509.MarshalPKCS8PrivateKey(id.key)
	valid, _ := json.Marshal(record{1, id.created, der})
	other, _ := ecdsa.GenerateKey(elliptic.P384(), rand.Reader)
	otherDER, _ := x509.MarshalPKCS8PrivateKey(other)
	otherRecord, _ := json.Marshal(record{1, id.created, otherDER})
	for _, plain := range [][]byte{
		nil, []byte("{}"), append(append([]byte(nil), valid...), []byte("{}")...),
		bytes.Replace(valid, []byte(`"version":1`), []byte(`"version":2`), 1),
		bytes.Replace(valid, []byte(`"version":1`), []byte(`"version":1,"version":1`), 1),
		bytes.Replace(valid, []byte(`"version":1`), []byte(`"version":1,"extra":true`), 1),
		bytes.Repeat([]byte(" "), maxPlainBytes+1), otherRecord,
	} {
		if _, err := decode(plain); !errors.Is(err, ErrInvalid) {
			t.Fatal("invalid record accepted", err)
		}
	}
}

type failingProtection struct{}

func (failingProtection) protect([]byte) ([]byte, error)   { return nil, errors.New("test") }
func (failingProtection) unprotect([]byte) ([]byte, error) { return nil, errors.New("test") }
func TestProtectionFailureDoesNotCreatePlaintextFallback(t *testing.T) {
	s := testStore(t)
	s.protection = failingProtection{}
	if _, _, err := s.Ensure(); !errors.Is(err, ErrUnavailable) {
		t.Fatal(err)
	}
	if _, err := os.Stat(s.directory); !errors.Is(err, os.ErrNotExist) {
		t.Fatal("created state despite protection failure", err)
	}
}

func TestReloadedKeySignsTLSAndRenewsAddressWithoutChangingIdentity(t *testing.T) {
	s := testStore(t)
	first, _, err := s.Ensure()
	if err != nil {
		t.Fatal(err)
	}
	now := time.Now()
	cert, err := first.Certificate(net.ParseIP("10.0.0.5"), now)
	if err != nil {
		t.Fatal(err)
	}
	reloaded, err := s.Load()
	if err != nil {
		t.Fatal(err)
	}
	renewed, err := reloaded.Certificate(net.ParseIP("192.168.1.5"), now.Add(time.Hour))
	if err != nil {
		t.Fatal(err)
	}
	if bytes.Equal(cert.Certificate[0], renewed.Certificate[0]) {
		t.Fatal("leaf was not renewed")
	}
	for _, c := range []tls.Certificate{cert, renewed} {
		pin, _ := PublicKeyFingerprint(c.Leaf.PublicKey)
		if pin != first.Info().Fingerprint {
			t.Fatal("certificate changed identity")
		}
	}
	if renewed.Leaf.VerifyHostname("192.168.1.5") != nil || renewed.Leaf.VerifyHostname("10.0.0.5") == nil {
		t.Fatal("address validation failed")
	}
	for _, address := range []string{"127.0.0.1", "8.8.8.8", "::1", ""} {
		if _, err := first.Certificate(net.ParseIP(address), now); err == nil {
			t.Fatal("invalid address accepted")
		}
	}
	server := httptest.NewUnstartedServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) { w.WriteHeader(204) }))
	server.TLS = &tls.Config{MinVersion: tls.VersionTLS13, Certificates: []tls.Certificate{renewed}}
	server.StartTLS()
	defer server.Close()
	roots := x509.NewCertPool()
	roots.AddCert(renewed.Leaf)
	transport := &http.Transport{TLSClientConfig: &tls.Config{MinVersion: tls.VersionTLS13, RootCAs: roots,
		ServerName: "192.168.1.5", Time: func() time.Time { return now.Add(time.Hour) }}}
	defer transport.CloseIdleConnections()
	client := &http.Client{Transport: transport, Timeout: 3 * time.Second}
	response, err := client.Get(server.URL)
	if err != nil {
		t.Fatal("reloaded signer failed a real TLS handshake", err)
	}
	io.Copy(io.Discard, response.Body)
	response.Body.Close()
	if response.StatusCode != 204 || response.TLS.Version != tls.VersionTLS13 {
		t.Fatal("unexpected TLS response")
	}
}

func TestPublicKeyFingerprintInteroperabilityVector(t *testing.T) {
	data, err := os.ReadFile("testdata/host_public_key_v1.json")
	if err != nil {
		t.Fatal(err)
	}
	var fixture struct {
		DER         string `json:"subject_public_key_info_der_hex"`
		Fingerprint string `json:"sha256_hex"`
	}
	if json.Unmarshal(data, &fixture) != nil {
		t.Fatal("invalid fixture")
	}
	der, err := hex.DecodeString(fixture.DER)
	if err != nil {
		t.Fatal(err)
	}
	public, err := x509.ParsePKIXPublicKey(der)
	if err != nil {
		t.Fatal(err)
	}
	got, err := PublicKeyFingerprint(public)
	if err != nil || got != fixture.Fingerprint {
		t.Fatalf("SPKI encoding/hash mismatch: %s %v", got, err)
	}
	for _, invalid := range []any{nil, (*ecdsa.PublicKey)(nil), &ecdsa.PublicKey{Curve: elliptic.P384()}, &ecdsa.PublicKey{Curve: elliptic.P256()}} {
		if _, err := PublicKeyFingerprint(invalid); err == nil {
			t.Fatal("invalid public key accepted")
		}
	}
}
