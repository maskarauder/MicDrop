// SPDX-License-Identifier: MPL-2.0
//go:build darwin || linux

package identity

import (
	"bytes"
	"os"
	"path/filepath"
	"testing"
)

func useTempKeystore(t *testing.T) string {
	t.Helper()
	dir := filepath.Join(t.TempDir(), "keystore")
	previous := testKeystoreDir
	testKeystoreDir = dir
	t.Cleanup(func() { testKeystoreDir = previous })
	return dir
}

func TestUnixProtectedIdentityRoundTripTamperingAndKeyPermissions(t *testing.T) {
	keystore := useTempKeystore(t)
	directory := filepath.Join(t.TempDir(), "identity")
	store, err := NewStore(directory)
	if err != nil {
		t.Fatal(err)
	}
	if _, err := os.Stat(keystore); !os.IsNotExist(err) {
		t.Fatal("NewStore created keystore before Ensure")
	}
	first, created, err := store.Ensure()
	if err != nil || !created {
		t.Fatal("creation failed", err)
	}
	reopened, _ := NewStore(directory)
	second, created, err := reopened.Ensure()
	if err != nil || created || first.Info() != second.Info() {
		t.Fatal("reopen changed identity", err)
	}
	data, err := os.ReadFile(filepath.Join(directory, Filename))
	if err != nil {
		t.Fatal(err)
	}
	if bytes.Contains(data, []byte("private_key_pkcs8")) {
		t.Fatal("plaintext file")
	}
	// Broadening permissions on the master key must fail closed without overwriting.
	keyPath := filepath.Join(keystore, masterKeyFilename)
	if err := os.Chmod(keyPath, 0o644); err != nil {
		t.Fatal(err)
	}
	if _, created, err := reopened.Ensure(); err == nil || created {
		t.Fatal("world-readable master key accepted")
	}
	if err := os.Chmod(keyPath, 0o600); err != nil {
		t.Fatal(err)
	}
	if _, created, err := reopened.Ensure(); err != nil || created {
		t.Fatal("restored master key failed", err)
	}
	data[len(data)-1] ^= 0x80
	if err := os.WriteFile(filepath.Join(directory, Filename), data, 0o600); err != nil {
		t.Fatal(err)
	}
	if _, created, err := reopened.Ensure(); err == nil || created {
		t.Fatal("tampered identity replaced or accepted")
	}
}

func TestUnixProtectorBounds(t *testing.T) {
	useTempKeystore(t)
	p, err := platformProtector()
	if err != nil {
		t.Fatal(err)
	}
	plain := []byte("MicDrop identity test")
	sealed, err := p.protect(plain)
	if err != nil || bytes.Equal(plain, sealed) {
		t.Fatal("protect failed", err)
	}
	opened, err := p.unprotect(sealed)
	if err != nil || !bytes.Equal(plain, opened) {
		t.Fatal("unprotect failed", err)
	}
	for _, invalid := range [][]byte{nil, {1, 2, 3}, make([]byte, maxFileBytes+1)} {
		if _, err := p.unprotect(invalid); err == nil {
			t.Fatal("invalid blob accepted")
		}
	}
}

func TestUnixRemoteSettingsProtectionPurposeAndForget(t *testing.T) {
	useTempKeystore(t)
	s, err := NewStore(t.TempDir())
	if err != nil {
		t.Fatal(err)
	}
	host, _, err := s.Ensure()
	if err != nil {
		t.Fatal(err)
	}
	lock, err := s.OpenPairing()
	if err != nil {
		t.Fatal(err)
	}
	defer lock.Close()
	plain := []byte(`{"version":1,"private-resource-token":"fixture-not-a-real-token"}`)
	if err := s.SaveRemote(plain); err != nil {
		t.Fatal(err)
	}
	loaded, err := s.LoadRemote()
	if err != nil || !bytes.Equal(plain, loaded) {
		t.Fatal("remote round trip", err)
	}
	sealed, err := os.ReadFile(filepath.Join(s.directory, RemoteFilename))
	if err != nil {
		t.Fatal(err)
	}
	if bytes.Contains(sealed, []byte("private-resource-token")) {
		t.Fatal("plaintext settings")
	}
	if _, err := s.protection.unprotect(sealed[len(remoteHeader):]); err == nil {
		t.Fatal("remote settings accepted as identity")
	}
	if _, err := lock.protection.unprotect(sealed[len(remoteHeader):]); err == nil {
		t.Fatal("remote settings accepted as grants")
	}
	sealed[len(sealed)-1] ^= 0x80
	if err := os.WriteFile(filepath.Join(s.directory, RemoteFilename), sealed, 0o600); err != nil {
		t.Fatal(err)
	}
	if _, err := s.LoadRemote(); err == nil {
		t.Fatal("tampered settings accepted")
	}
	if err := s.ForgetRemote(); err != nil {
		t.Fatal(err)
	}
	if _, err := s.LoadRemote(); !os.IsNotExist(err) {
		t.Fatal("settings not removed")
	}
	current, _, err := s.Ensure()
	if err != nil || current.Info() != host.Info() {
		t.Fatal("forget changed identity")
	}
}

func TestUnixProtectedGrantsLockReplacementAndPurpose(t *testing.T) {
	useTempKeystore(t)
	s, err := NewStore(t.TempDir())
	if err != nil {
		t.Fatal(err)
	}
	if _, _, err = s.Ensure(); err != nil {
		t.Fatal(err)
	}
	grants, err := s.OpenPairing()
	if err != nil {
		t.Fatal(err)
	}
	defer grants.Close()
	if other, err := s.OpenPairing(); err == nil {
		other.Close()
		t.Fatal("second writer acquired live lock")
	}
	for _, plain := range [][]byte{[]byte(`{"test":1}`), bytes.Repeat([]byte("a"), MaxPairingBytes)} {
		if err := grants.Save(plain); err != nil {
			t.Fatal(err)
		}
		loaded, err := grants.Load()
		if err != nil || !bytes.Equal(loaded, plain) {
			t.Fatal("grant replacement failed", err)
		}
	}
	sealed, err := grants.protection.protect([]byte("grant"))
	if err != nil {
		t.Fatal(err)
	}
	if _, err := s.protection.unprotect(sealed); err == nil {
		t.Fatal("grant binding accepted as identity")
	}
	if err := grants.Close(); err != nil {
		t.Fatal(err)
	}
	reopened, err := s.OpenPairing()
	if err != nil {
		t.Fatal("closed lock not released", err)
	}
	defer reopened.Close()
	if _, err := reopened.Load(); err != nil {
		t.Fatal(err)
	}
}
