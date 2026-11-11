package identity

import (
	"bytes"
	"errors"
	"io"
	"os"
	"path/filepath"
)

const RemoteFilename = "remote-connection-v1.dpapi"

var remoteHeader = []byte{'M', 'D', 'R', 'C', 1}

// The caller holds OpenPairing's exclusive lock when changing configuration.
// Remote credentials have a separate DPAPI purpose from identity and grants.
func (s *Store) SaveRemote(plain []byte) error {
	if len(plain) == 0 || len(plain) > 4096 {
		return ErrInvalid
	}
	p, err := platformRemoteProtector()
	if err != nil {
		return err
	}
	encrypted, err := p.protect(plain)
	if err != nil || len(encrypted) == 0 || len(encrypted)+len(remoteHeader) > maxFileBytes {
		return ErrUnavailable
	}
	path := filepath.Join(s.directory, RemoteFilename)
	if info, err := os.Lstat(path); err == nil && !info.Mode().IsRegular() {
		return ErrInvalid
	} else if err != nil && !errors.Is(err, os.ErrNotExist) {
		return ErrUnavailable
	}
	f, err := os.CreateTemp(s.directory, ".remote-*.tmp")
	if err != nil {
		return ErrUnavailable
	}
	defer os.Remove(f.Name())
	_, writeErr := f.Write(append(append([]byte(nil), remoteHeader...), encrypted...))
	syncErr := f.Sync()
	closeErr := f.Close()
	if writeErr != nil || syncErr != nil || closeErr != nil || replacePairing(f.Name(), path) != nil {
		return ErrUnavailable
	}
	check, err := s.LoadRemote()
	defer clear(check)
	if err != nil || !bytes.Equal(check, plain) {
		return ErrUnavailable
	}
	return nil
}
func (s *Store) LoadRemote() ([]byte, error) {
	p, err := platformRemoteProtector()
	if err != nil {
		return nil, err
	}
	path := filepath.Join(s.directory, RemoteFilename)
	info, err := os.Lstat(path)
	if err != nil {
		return nil, err
	}
	if !info.Mode().IsRegular() || info.Size() > maxFileBytes {
		return nil, ErrInvalid
	}
	f, err := os.Open(path)
	if err != nil {
		return nil, ErrUnavailable
	}
	defer f.Close()
	data, err := io.ReadAll(io.LimitReader(f, maxFileBytes+1))
	if err != nil || len(data) > maxFileBytes || !bytes.HasPrefix(data, remoteHeader) {
		return nil, ErrInvalid
	}
	plain, err := p.unprotect(data[len(remoteHeader):])
	if err != nil || len(plain) == 0 || len(plain) > 4096 {
		clear(plain)
		return nil, ErrInvalid
	}
	return plain, nil
}
func (s *Store) ForgetRemote() error {
	err := os.Remove(filepath.Join(s.directory, RemoteFilename))
	if errors.Is(err, os.ErrNotExist) {
		return nil
	}
	return err
}
