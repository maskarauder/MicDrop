package identity

import (
	"bytes"
	"errors"
	"io"
	"os"
	"path/filepath"
)

const PairingFilename = "paired-devices-v1.dpapi"
const MaxPairingBytes = 12 * 1024

var pairingHeader = []byte{'M', 'D', 'P', 'G', 1}

// PairingStore owns an exclusive OS lock for the listener's lifetime. Console
// commands are handled by that listener, never by a second state-file writer.
type PairingStore struct {
	directory  string
	protection protector
	lock       io.Closer
}

func (s *Store) OpenPairing() (*PairingStore, error) {
	if _, err := s.Load(); err != nil {
		return nil, err
	}
	p, err := platformPairingProtector()
	if err != nil {
		return nil, err
	}
	lock, err := lockPairing(filepath.Join(s.directory, "paired-listener.lock"))
	if err != nil {
		return nil, ErrUnavailable
	}
	return &PairingStore{s.directory, p, lock}, nil
}

func (s *PairingStore) Close() error { return s.lock.Close() }

func (s *PairingStore) Load() ([]byte, error) {
	path := filepath.Join(s.directory, PairingFilename)
	info, err := os.Lstat(path)
	if errors.Is(err, os.ErrNotExist) {
		return nil, os.ErrNotExist
	}
	if err != nil {
		return nil, ErrUnavailable
	}
	if !info.Mode().IsRegular() || info.Size() > maxFileBytes || info.Size() <= int64(len(pairingHeader)) {
		return nil, ErrInvalid
	}
	f, err := os.Open(path)
	if err != nil {
		return nil, ErrUnavailable
	}
	defer f.Close()
	data, err := io.ReadAll(io.LimitReader(f, maxFileBytes+1))
	if err != nil {
		return nil, ErrUnavailable
	}
	if len(data) > maxFileBytes || !bytes.HasPrefix(data, pairingHeader) {
		return nil, ErrInvalid
	}
	plain, err := s.protection.unprotect(data[len(pairingHeader):])
	if err != nil || len(plain) == 0 || len(plain) > MaxPairingBytes {
		clear(plain)
		return nil, ErrInvalid
	}
	return plain, nil
}

func (s *PairingStore) Save(plain []byte) error {
	if len(plain) == 0 || len(plain) > MaxPairingBytes {
		return ErrInvalid
	}
	encrypted, err := s.protection.protect(plain)
	if err != nil || len(encrypted) == 0 || len(encrypted)+len(pairingHeader) > maxFileBytes {
		return ErrUnavailable
	}
	path := filepath.Join(s.directory, PairingFilename)
	if info, err := os.Lstat(path); err == nil && !info.Mode().IsRegular() {
		return ErrInvalid
	} else if err != nil && !errors.Is(err, os.ErrNotExist) {
		return ErrUnavailable
	}
	f, err := os.CreateTemp(s.directory, ".grants-*.tmp")
	if err != nil {
		return ErrUnavailable
	}
	defer os.Remove(f.Name())
	_, writeErr := f.Write(append(append([]byte(nil), pairingHeader...), encrypted...))
	syncErr := f.Sync()
	closeErr := f.Close()
	if writeErr != nil || syncErr != nil || closeErr != nil {
		return ErrUnavailable
	}
	if replacePairing(f.Name(), path) != nil {
		return ErrUnavailable
	}
	check, err := s.Load()
	defer clear(check)
	if err != nil || !bytes.Equal(check, plain) {
		return ErrUnavailable
	}
	return nil
}
