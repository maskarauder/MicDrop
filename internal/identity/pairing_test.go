package identity

import (
	"bytes"
	"errors"
	"os"
	"path/filepath"
	"testing"
)

func TestProtectedGrantReplacementAndTampering(t *testing.T) {
	s := &PairingStore{directory: t.TempDir(), protection: protectionForTest(t)}
	if _, err := s.Load(); !errors.Is(err, os.ErrNotExist) {
		t.Fatal(err)
	}
	for _, plain := range [][]byte{[]byte(`{"test_grant":1}`), []byte(`{"test_grant":2,"revoked":true}`)} {
		if err := s.Save(plain); err != nil {
			t.Fatal(err)
		}
		got, err := s.Load()
		if err != nil || !bytes.Equal(got, plain) {
			t.Fatal("replacement failed", err)
		}
		data, _ := os.ReadFile(filepath.Join(s.directory, PairingFilename))
		if bytes.Contains(data, plain) {
			t.Fatal("plaintext grant")
		}
	}
	path := filepath.Join(s.directory, PairingFilename)
	data, _ := os.ReadFile(path)
	data[len(data)-1] ^= 128
	if err := os.WriteFile(path, data, 0600); err != nil {
		t.Fatal(err)
	}
	if _, err := s.Load(); err == nil {
		t.Fatal("tampered grants accepted")
	}
	leftovers, _ := filepath.Glob(filepath.Join(s.directory, ".grants-*.tmp"))
	if len(leftovers) != 0 {
		t.Fatal("temporary grant files leaked")
	}
}

func TestExistingGrantsPreventSilentIdentityReplacement(t *testing.T) {
	s := testStore(t)
	if err := os.MkdirAll(s.directory, 0700); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(s.directory, PairingFilename), []byte("existing grants"), 0600); err != nil {
		t.Fatal(err)
	}
	if _, created, err := s.Ensure(); err == nil || created {
		t.Fatal("missing identity was replaced under existing grants")
	}
	if _, err := os.Stat(filepath.Join(s.directory, Filename)); !errors.Is(err, os.ErrNotExist) {
		t.Fatal("replacement file created")
	}
}
