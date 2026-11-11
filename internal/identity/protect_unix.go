// SPDX-License-Identifier: MPL-2.0
//go:build darwin || linux

package identity

import (
	"bytes"
	"crypto/aes"
	"crypto/cipher"
	"crypto/hmac"
	"crypto/rand"
	"crypto/sha256"
	"errors"
	"io"
	"os"
	"path/filepath"
	"strconv"
	"syscall"
)

const (
	masterKeyFilename = "master-key-v1.key"
	masterKeyBytes    = 32
)

var (
	masterKeyHeader = []byte{'M', 'D', 'M', 'K', 1}
	envelopeHeader  = []byte{'M', 'D', 'A', 'E', 1}
	// Overridden only by unit tests in this package to isolate temporary keystores.
	testKeystoreDir string
)

type unixProtector struct {
	purpose string
	limit   int
}

func protectionLabel() string { return "unix_user_keystore_aead_v1" }

func platformProtector() (protector, error) {
	if _, err := keystoreDirectory(); err != nil {
		return nil, ErrUnavailable
	}
	return unixProtector{purpose: "MicDrop host identity / AEAD / version 1", limit: maxPlainBytes}, nil
}

func platformPairingProtector() (protector, error) {
	if _, err := keystoreDirectory(); err != nil {
		return nil, ErrUnavailable
	}
	return unixProtector{purpose: "MicDrop paired devices / AEAD / version 1", limit: MaxPairingBytes}, nil
}

func platformRemoteProtector() (protector, error) {
	if _, err := keystoreDirectory(); err != nil {
		return nil, ErrUnavailable
	}
	return unixProtector{purpose: "MicDrop remote connection / AEAD / version 1", limit: 4096}, nil
}

func keystoreDirectory() (string, error) {
	if testKeystoreDir != "" {
		if !filepath.IsAbs(testKeystoreDir) {
			return "", ErrUnavailable
		}
		return filepath.Clean(testKeystoreDir), nil
	}
	base, err := os.UserConfigDir()
	if err != nil || base == "" || !filepath.IsAbs(base) {
		return "", ErrUnavailable
	}
	return filepath.Join(base, "MicDrop", "keystore"), nil
}

func verifyKeystoreDir(dir string) error {
	info, err := os.Lstat(dir)
	if err != nil {
		return err
	}
	st, ok := info.Sys().(*syscall.Stat_t)
	if !info.IsDir() || info.Mode()&os.ModeSymlink != 0 || info.Mode().Perm()&0o077 != 0 || !ok || int(st.Uid) != os.Geteuid() {
		return ErrInvalid
	}
	return nil
}

func readMasterKey(path string) ([]byte, error) {
	fd, err := syscall.Open(path, syscall.O_RDONLY|syscall.O_CLOEXEC|syscall.O_NOFOLLOW, 0)
	if err != nil {
		if errors.Is(err, syscall.ENOENT) {
			return nil, os.ErrNotExist
		}
		return nil, err
	}
	file := os.NewFile(uintptr(fd), path)
	defer file.Close()
	var st syscall.Stat_t
	if err := syscall.Fstat(fd, &st); err != nil {
		return nil, err
	}
	expectedSize := int64(len(masterKeyHeader) + masterKeyBytes)
	if (st.Mode&syscall.S_IFMT) != syscall.S_IFREG || (st.Mode&0o077) != 0 || int(st.Uid) != os.Geteuid() || st.Size != expectedSize {
		return nil, ErrInvalid
	}
	raw, err := io.ReadAll(io.LimitReader(file, expectedSize+1))
	if err != nil || int64(len(raw)) != expectedSize || !bytes.HasPrefix(raw, masterKeyHeader) {
		clear(raw)
		return nil, ErrInvalid
	}
	key := append([]byte(nil), raw[len(masterKeyHeader):]...)
	clear(raw)
	return key, nil
}

func loadOrCreateMasterKey(create bool) ([]byte, error) {
	dir, err := keystoreDirectory()
	if err != nil {
		return nil, err
	}
	path := filepath.Join(dir, masterKeyFilename)
	if err := verifyKeystoreDir(dir); err == nil {
		key, readErr := readMasterKey(path)
		if !errors.Is(readErr, os.ErrNotExist) || !create {
			return key, readErr
		}
	} else if !errors.Is(err, os.ErrNotExist) || !create {
		return nil, err
	} else {
		if err := os.MkdirAll(dir, 0o700); err != nil {
			return nil, ErrUnavailable
		}
		if err := verifyKeystoreDir(dir); err != nil {
			return nil, err
		}
	}
	secret := make([]byte, masterKeyBytes)
	if _, err := rand.Read(secret); err != nil {
		clear(secret)
		return nil, ErrUnavailable
	}
	defer clear(secret)
	staged, err := os.CreateTemp(dir, ".keystore-*.tmp")
	if err != nil {
		return nil, ErrUnavailable
	}
	defer os.Remove(staged.Name())
	if err := staged.Chmod(0o600); err != nil {
		staged.Close()
		return nil, ErrUnavailable
	}
	payload := append(append([]byte(nil), masterKeyHeader...), secret...)
	defer clear(payload)
	_, writeErr := staged.Write(payload)
	syncErr := staged.Sync()
	closeErr := staged.Close()
	if writeErr != nil || syncErr != nil || closeErr != nil {
		return nil, ErrUnavailable
	}
	if err := os.Link(staged.Name(), path); err != nil && !errors.Is(err, os.ErrExist) {
		return nil, ErrUnavailable
	}
	return readMasterKey(path)
}

func deriveAEAD(master []byte, purpose string) (cipher.AEAD, []byte, error) {
	mac := hmac.New(sha256.New, master)
	_, _ = mac.Write([]byte(purpose))
	_, _ = mac.Write([]byte{0})
	aad := []byte(purpose + "/uid=" + strconv.Itoa(os.Geteuid()))
	_, _ = mac.Write(aad)
	derived := mac.Sum(nil)
	defer clear(derived)
	block, err := aes.NewCipher(derived)
	if err != nil {
		return nil, nil, err
	}
	aead, err := cipher.NewGCM(block)
	if err != nil {
		return nil, nil, err
	}
	return aead, aad, nil
}

func (p unixProtector) protect(data []byte) ([]byte, error) {
	if len(data) == 0 || len(data) > p.limit {
		return nil, errors.New("invalid protected data size")
	}
	master, err := loadOrCreateMasterKey(true)
	if err != nil {
		return nil, err
	}
	defer clear(master)
	aead, aad, err := deriveAEAD(master, p.purpose)
	if err != nil {
		return nil, err
	}
	nonce := make([]byte, aead.NonceSize())
	if _, err := rand.Read(nonce); err != nil {
		return nil, err
	}
	out := make([]byte, 0, len(envelopeHeader)+len(nonce)+len(data)+aead.Overhead())
	out = append(out, envelopeHeader...)
	out = append(out, nonce...)
	out = aead.Seal(out, nonce, data, aad)
	if len(out) > maxFileBytes {
		clear(out)
		return nil, ErrInvalid
	}
	return out, nil
}

func (p unixProtector) unprotect(data []byte) ([]byte, error) {
	if len(data) <= len(envelopeHeader) || len(data) > maxFileBytes || !bytes.HasPrefix(data, envelopeHeader) {
		return nil, ErrInvalid
	}
	master, err := loadOrCreateMasterKey(false)
	if err != nil {
		return nil, ErrInvalid
	}
	defer clear(master)
	aead, aad, err := deriveAEAD(master, p.purpose)
	if err != nil {
		return nil, ErrInvalid
	}
	body := data[len(envelopeHeader):]
	if len(body) < aead.NonceSize()+aead.Overhead() {
		return nil, ErrInvalid
	}
	plain, err := aead.Open(nil, body[:aead.NonceSize()], body[aead.NonceSize():], aad)
	if err != nil || len(plain) == 0 || len(plain) > p.limit {
		clear(plain)
		return nil, ErrInvalid
	}
	return plain, nil
}
