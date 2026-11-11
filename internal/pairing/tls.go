package pairing

import (
	"crypto/tls"
	"crypto/x509"
	"errors"
	"net/http"
	"time"

	"github.com/maskarauder/MicDrop/internal/identity"
)

// TLS 1.3 CertificateVerify proves private-key possession. We validate the
// self-signed certificate's shape/time/use, then authorize its SPKI on every
// request. Unknown keys can only reach the locally opened enrollment route.
func ClientKey(cs *tls.ConnectionState, now time.Time) (string, error) {
	if cs == nil || cs.Version != tls.VersionTLS13 || len(cs.PeerCertificates) != 1 {
		return "", errors.New("client certificate required")
	}
	c := cs.PeerCertificates[0]
	if now.Before(c.NotBefore) || !now.Before(c.NotAfter) || len(c.UnhandledCriticalExtensions) != 0 || c.KeyUsage != 0 && c.KeyUsage&x509.KeyUsageDigitalSignature == 0 {
		return "", errors.New("invalid client certificate")
	}
	if len(c.ExtKeyUsage) != 0 {
		valid := false
		for _, usage := range c.ExtKeyUsage {
			if usage == x509.ExtKeyUsageClientAuth || usage == x509.ExtKeyUsageAny {
				valid = true
			}
		}
		if !valid {
			return "", errors.New("invalid client certificate use")
		}
	}
	if c.CheckSignature(c.SignatureAlgorithm, c.RawTBSCertificate, c.Signature) != nil {
		return "", errors.New("invalid client certificate signature")
	}
	return identity.PublicKeyFingerprint(c.PublicKey)
}
func (m *Manager) Client(r *http.Request) (string, bool) {
	key, err := ClientKey(r.TLS, m.now())
	return key, err == nil && m.Allowed(key)
}
func (m *Manager) TLSConfig(certificate func(*tls.ClientHelloInfo) (*tls.Certificate, error)) *tls.Config {
	return &tls.Config{MinVersion: tls.VersionTLS13, MaxVersion: tls.VersionTLS13,
		ClientAuth: tls.RequireAnyClientCert, GetCertificate: certificate,
		SessionTicketsDisabled: true, // Full key proof each handshake in this increment.
		VerifyConnection:       func(cs tls.ConnectionState) error { _, err := ClientKey(&cs, m.now()); return err },
	}
}
