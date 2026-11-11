package identity

import (
	"bytes"
	"crypto/ecdsa"
	"crypto/elliptic"
	"crypto/x509"
	"encoding/json"
	"errors"
	"io"
	"os"
	"path/filepath"
	"time"
)

const (
	Filename      = "host-identity-v1.dpapi"
	maxFileBytes  = 16 * 1024
	maxPlainBytes = 1024
)

var fileHeader = []byte{'M', 'D', 'H', 'I', 1}

type protector interface {
	protect([]byte) ([]byte, error)
	unprotect([]byte) ([]byte, error)
}

type Store struct {
	directory  string
	protection protector
}

// NewStore never creates files. The platform adapter has no plaintext fallback.
func NewStore(directory string) (*Store, error) {
	protection, err := platformProtector()
	if err != nil {
		return nil, err
	}
	if directory == "" || !filepath.IsAbs(directory) {
		return nil, ErrUnavailable
	}
	return &Store{directory: filepath.Clean(directory), protection: protection}, nil
}

func DefaultDirectory() (string, error) {
	if _, err := platformProtector(); err != nil {
		return "", err
	}
	base, err := os.UserCacheDir() // %LOCALAPPDATA% on Windows, not the executable directory.
	if err != nil || !filepath.IsAbs(base) {
		return "", ErrUnavailable
	}
	return filepath.Join(base, "MicDrop", "identity"), nil
}

type record struct {
	Version    int       `json:"version"`
	CreatedAt  time.Time `json:"created_at"`
	PrivateKey []byte    `json:"private_key_pkcs8"`
}

func decode(plain []byte) (*Identity, error) {
	if len(plain) > maxPlainBytes {
		return nil, ErrInvalid
	}
	var value record
	d := json.NewDecoder(bytes.NewReader(plain))
	d.DisallowUnknownFields()
	if d.Decode(&value) != nil || d.Decode(new(any)) != io.EOF || value.Version != 1 ||
		value.CreatedAt.IsZero() || value.CreatedAt.Year() < 1970 || value.CreatedAt.Year() > 9998 {
		return nil, ErrInvalid
	}
	defer clear(value.PrivateKey)
	parsed, err := x509.ParsePKCS8PrivateKey(value.PrivateKey)
	if err != nil {
		return nil, ErrInvalid
	}
	key, ok := parsed.(*ecdsa.PrivateKey)
	if !ok || key.Curve != elliptic.P256() {
		return nil, ErrInvalid
	}
	// Canonical encoding rejects duplicate/reordered fields and unexpected data.
	canonical, err := json.Marshal(value)
	defer clear(canonical)
	if err != nil || !bytes.Equal(plain, canonical) {
		return nil, ErrInvalid
	}
	return &Identity{key: key, created: value.CreatedAt}, nil
}

func (s *Store) Load() (*Identity, error) {
	path := filepath.Join(s.directory, Filename)
	info, err := os.Lstat(path)
	if errors.Is(err, os.ErrNotExist) {
		return nil, os.ErrNotExist
	}
	if err != nil {
		return nil, ErrUnavailable
	}
	if !info.Mode().IsRegular() || info.Size() > maxFileBytes || info.Size() <= int64(len(fileHeader)) {
		return nil, ErrInvalid
	}
	file, err := os.Open(path)
	if err != nil {
		return nil, ErrUnavailable
	}
	defer file.Close()
	encrypted, err := io.ReadAll(io.LimitReader(file, maxFileBytes+1))
	if err != nil {
		return nil, ErrUnavailable
	}
	if len(encrypted) > maxFileBytes || !bytes.HasPrefix(encrypted, fileHeader) {
		return nil, ErrInvalid
	}
	plain, err := s.protection.unprotect(encrypted[len(fileHeader):])
	if err != nil {
		return nil, ErrInvalid
	}
	defer clear(plain)
	return decode(plain)
}

// Ensure creates one identity only when the final file is absent. A corrupt,
// unsupported or inaccessible existing file is never replaced automatically.
// Atomic no-replace publication also makes concurrent first starts converge.
func (s *Store) Ensure() (*Identity, bool, error) {
	if current, err := s.Load(); !errors.Is(err, os.ErrNotExist) {
		return current, false, err
	}
	// An existing grant database belongs to the missing key. Never silently
	// create a replacement identity that strands or misattributes those grants.
	if _, err := os.Lstat(filepath.Join(s.directory, PairingFilename)); !errors.Is(err, os.ErrNotExist) {
		return nil, false, ErrInvalid
	}
	candidate, err := generate(time.Now())
	if err != nil {
		return nil, false, ErrUnavailable
	}
	key, err := x509.MarshalPKCS8PrivateKey(candidate.key)
	if err != nil {
		return nil, false, ErrUnavailable
	}
	defer clear(key)
	plain, err := json.Marshal(record{1, candidate.created, key})
	if err != nil {
		return nil, false, ErrUnavailable
	}
	defer clear(plain)
	encrypted, err := s.protection.protect(plain)
	if err != nil || len(encrypted) == 0 || len(encrypted)+len(fileHeader) > maxFileBytes {
		return nil, false, ErrUnavailable
	}
	if os.MkdirAll(s.directory, 0700) != nil {
		return nil, false, ErrUnavailable
	}
	staged, err := os.CreateTemp(s.directory, ".identity-*.tmp")
	if err != nil {
		return nil, false, ErrUnavailable
	}
	defer os.Remove(staged.Name())
	data := append(append([]byte(nil), fileHeader...), encrypted...)
	_, writeErr := staged.Write(data)
	syncErr := staged.Sync()
	closeErr := staged.Close()
	if writeErr != nil || syncErr != nil || closeErr != nil {
		return nil, false, ErrUnavailable
	}
	// Same-directory hard link publishes the already-flushed complete file and
	// fails if a final identity exists. Do not replace this with overwrite rename.
	err = os.Link(staged.Name(), filepath.Join(s.directory, Filename))
	created := err == nil
	if err != nil && !errors.Is(err, os.ErrExist) {
		return nil, false, ErrUnavailable
	}
	current, err := s.Load() // Verify the actual published identity before success.
	if err != nil {
		return nil, false, err
	}
	if created && current.Info().Fingerprint != candidate.Info().Fingerprint {
		return nil, false, ErrInvalid
	}
	return current, created, nil
}
