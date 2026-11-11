package session

import (
	"crypto/ecdsa"
	"crypto/elliptic"
	"crypto/rand"
	"crypto/sha256"
	"crypto/tls"
	"crypto/x509"
	"encoding/base64"
	"encoding/hex"
	"encoding/json"
	"math/big"
	"net"
	"time"
)

type Invitation struct {
	Host        string `json:"host"`
	Port        int    `json:"port"`
	Fingerprint string `json:"fingerprint"`
	Token       string `json:"token"`
	ExpiresAt   int64  `json:"expires_at,omitempty"`
}

func Secret() (string, error) {
	var value [32]byte
	if _, err := rand.Read(value[:]); err != nil {
		return "", err
	}
	return base64.RawURLEncoding.EncodeToString(value[:]), nil
}

// Ephemeral TLS identity; the invitation authenticates its SHA-256 fingerprint.
// Nothing is persisted, and the private key never enters the invitation.
func Identity(ip net.IP, now time.Time) (tls.Certificate, string, error) {
	key, err := ecdsa.GenerateKey(elliptic.P256(), rand.Reader)
	if err != nil {
		return tls.Certificate{}, "", err
	}
	serial, err := rand.Int(rand.Reader, new(big.Int).Lsh(big.NewInt(1), 128))
	if err != nil {
		return tls.Certificate{}, "", err
	}
	cert := &x509.Certificate{
		SerialNumber: serial, NotBefore: now.Add(-time.Hour), NotAfter: now.Add(24 * time.Hour),
		IPAddresses: []net.IP{ip}, KeyUsage: x509.KeyUsageDigitalSignature,
		ExtKeyUsage:           []x509.ExtKeyUsage{x509.ExtKeyUsageServerAuth},
		BasicConstraintsValid: true,
	}
	der, err := x509.CreateCertificate(rand.Reader, cert, cert, &key.PublicKey, key)
	if err != nil {
		return tls.Certificate{}, "", err
	}
	fingerprint := sha256.Sum256(der)
	return tls.Certificate{Certificate: [][]byte{der}, PrivateKey: key}, hex.EncodeToString(fingerprint[:]), nil
}

func (i Invitation) String() string {
	data, _ := json.Marshal(i)
	version := "v1"
	if i.ExpiresAt != 0 {
		version = "v2"
	}
	return "micdrop://" + version + "/" + base64.RawURLEncoding.EncodeToString(data)
}
