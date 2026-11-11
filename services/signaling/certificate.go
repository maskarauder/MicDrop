package main

import (
	"bytes"
	"crypto/tls"
	"crypto/x509"
	"errors"
	"io"
	"os"
	"sync/atomic"
	"time"
)

const certificateFileLimit = 1024 * 1024

// Only the service loop reloads. Handshakes read an immutable, validated pair;
// neither file I/O nor an interrupted certificate deployment affects a tunnel.
type certificateReloader struct {
	certFile, keyFile, name string
	current                 atomic.Pointer[tls.Certificate]
}

func newCertificateReloader(certFile, keyFile, name string) (*certificateReloader, error) {
	r := &certificateReloader{certFile: certFile, keyFile: keyFile, name: name}
	_, err := r.reload(time.Now())
	return r, err
}

func readCertificateFile(path string) ([]byte, error) {
	// Reject an accidentally configured FIFO/device before Open could block.
	info, err := os.Stat(path)
	if err != nil || !info.Mode().IsRegular() {
		return nil, errors.New("invalid certificate file")
	}
	f, err := os.Open(path)
	if err != nil {
		return nil, err
	}
	defer f.Close()
	info, err = f.Stat()
	if err != nil || !info.Mode().IsRegular() || info.Size() > certificateFileLimit {
		return nil, errors.New("invalid certificate file")
	}
	b, err := io.ReadAll(io.LimitReader(f, certificateFileLimit+1))
	if err != nil || len(b) > certificateFileLimit {
		return nil, errors.New("cannot read certificate file")
	}
	return b, nil
}

func (r *certificateReloader) reload(now time.Time) (bool, error) {
	certPEM, err := readCertificateFile(r.certFile)
	if err != nil {
		return false, err
	}
	keyPEM, err := readCertificateFile(r.keyFile)
	if err != nil {
		return false, err
	}
	pair, err := tls.X509KeyPair(certPEM, keyPEM)
	if err != nil {
		return false, err
	}
	leaf, err := x509.ParseCertificate(pair.Certificate[0])
	if err != nil {
		return false, err
	}
	if now.Before(leaf.NotBefore) || !now.Before(leaf.NotAfter) {
		return false, errors.New("certificate is outside its validity period")
	}
	if r.name != "" {
		if err := leaf.VerifyHostname(r.name); err != nil {
			return false, err
		}
	}
	pair.Leaf = leaf
	if old := r.current.Load(); old != nil && sameChain(old.Certificate, pair.Certificate) {
		return false, nil
	}
	r.current.Store(&pair)
	return true, nil
}

func sameChain(a, b [][]byte) bool {
	if len(a) != len(b) {
		return false
	}
	for i := range a {
		if !bytes.Equal(a[i], b[i]) {
			return false
		}
	}
	return true
}

func (r *certificateReloader) getCertificate(_ *tls.ClientHelloInfo) (*tls.Certificate, error) {
	pair := r.current.Load()
	now := time.Now()
	if pair == nil || now.Before(pair.Leaf.NotBefore) || !now.Before(pair.Leaf.NotAfter) {
		return nil, errors.New("rendezvous certificate is unavailable or expired")
	}
	return pair, nil
}
