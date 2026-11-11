// Package identity owns the persistent Windows host key for durable pairing.
// The opt-in v3 listener uses it; legacy v2 streams remain ephemeral.
package identity

import (
	"crypto"
	"crypto/ecdsa"
	"crypto/elliptic"
	"crypto/rand"
	"crypto/sha256"
	"crypto/tls"
	"crypto/x509"
	"encoding/hex"
	"encoding/json"
	"errors"
	"math/big"
	"net"
	"time"
)

var (
	ErrUnsupported = errors.New("protected host identity storage requires Windows")
	ErrUnavailable = errors.New("host identity storage is unavailable; no identity was replaced")
	ErrInvalid     = errors.New("host identity cannot be read or validated; preserve the file and use the original Windows account")
)

// Identity deliberately exposes neither key export nor JSON private material.
type Identity struct {
	key     *ecdsa.PrivateKey
	created time.Time
}

type Info struct {
	Version     int       `json:"version"`
	Algorithm   string    `json:"algorithm"`
	Fingerprint string    `json:"public_key_sha256"`
	CreatedAt   time.Time `json:"created_at"`
	Protection  string    `json:"protection"`
}

func generate(now time.Time) (*Identity, error) {
	if now.Year() < 1970 || now.Year() > 9998 {
		return nil, ErrUnavailable
	}
	key, err := ecdsa.GenerateKey(elliptic.P256(), rand.Reader)
	if err != nil {
		return nil, err
	}
	return &Identity{key: key, created: now.UTC().Truncate(time.Second)}, nil
}

// PublicKeyFingerprint hashes canonical X.509 SubjectPublicKeyInfo DER.
// It is an identifier; displaying it alone does not authorize a peer.
func PublicKeyFingerprint(key crypto.PublicKey) (string, error) {
	public, ok := key.(*ecdsa.PublicKey)
	if !ok || public == nil || public.Curve != elliptic.P256() ||
		public.X == nil || public.Y == nil || !public.Curve.IsOnCurve(public.X, public.Y) {
		return "", errors.New("expected an ECDSA P-256 public key")
	}
	der, err := x509.MarshalPKIXPublicKey(public)
	if err != nil {
		return "", err
	}
	hash := sha256.Sum256(der)
	return hex.EncodeToString(hash[:]), nil
}

func (i *Identity) Info() Info {
	fingerprint, _ := PublicKeyFingerprint(&i.key.PublicKey)
	return Info{Version: 1, Algorithm: "ECDSA_P256", Fingerprint: fingerprint,
		CreatedAt: i.created, Protection: "windows_dpapi_current_user"}
}
func (i *Identity) MarshalJSON() ([]byte, error) { return json.Marshal(i.Info()) }
func (i *Identity) String() string               { return "MicDrop host identity " + i.Info().Fingerprint }
func (i *Identity) GoString() string             { return i.String() }

// Certificate proves that a reloaded key can sign a fresh TLS certificate for
// the current address. Paired v3 clients pin its public key, not the leaf bytes.
func (i *Identity) Certificate(ip net.IP, now time.Time) (tls.Certificate, error) {
	if ip == nil || ip.To4() == nil || !ip.IsPrivate() {
		return tls.Certificate{}, errors.New("a private IPv4 address is required")
	}
	serial, err := rand.Int(rand.Reader, new(big.Int).Lsh(big.NewInt(1), 128))
	if err != nil {
		return tls.Certificate{}, err
	}
	serial.Add(serial, big.NewInt(1))
	template := &x509.Certificate{SerialNumber: serial, NotBefore: now.Add(-5 * time.Minute),
		NotAfter: now.Add(24 * time.Hour), IPAddresses: []net.IP{ip.To4()},
		KeyUsage: x509.KeyUsageDigitalSignature, ExtKeyUsage: []x509.ExtKeyUsage{x509.ExtKeyUsageServerAuth},
		BasicConstraintsValid: true}
	der, err := x509.CreateCertificate(rand.Reader, template, template, &i.key.PublicKey, i.key)
	if err != nil {
		return tls.Certificate{}, err
	}
	leaf, err := x509.ParseCertificate(der)
	if err != nil {
		return tls.Certificate{}, err
	}
	return tls.Certificate{Certificate: [][]byte{der}, PrivateKey: i.key, Leaf: leaf}, nil
}
