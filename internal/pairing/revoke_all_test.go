package pairing

import (
	"bytes"
	"crypto/tls"
	"errors"
	"strings"
	"testing"
)

func TestRevokeAllFreesCapacityPersistsAndBurnsOldEnrollment(t *testing.T) {
	storage := &memoryStore{}
	m := testManager(t, storage)
	hostKey := m.HostKey()
	var oldKeys []string
	var oldPhones []tls.Certificate
	var invitations []Invitation
	for range MaxDevices {
		phone := testCertificate(t, true)
		oldPhones = append(oldPhones, phone)
		invitations = append(invitations, approve(t, m, phone))
		oldKeys = append(oldKeys, keyOf(phone))
	}
	newPhone := testCertificate(t, true)
	window, err := m.Open("192.168.1.2", 9844)
	if err != nil || enrollment(t, m, newPhone, window.Secret).Code != 200 {
		t.Fatal("could not request enrollment at capacity", err)
	}
	id := m.pending.ID
	if err := m.Approve(id); err == nil || !strings.Contains(err.Error(), "revoke-all") {
		t.Fatal("limit accepted a new phone or did not explain bulk removal", err)
	}
	count, err := m.RevokeAll()
	if err != nil || count != MaxDevices || len(m.Devices()) != 0 || m.HostKey() != hostKey {
		t.Fatal("bulk reset failed or changed the host identity", count, err)
	}
	if !errors.Is(m.Approve(id), ErrRequest) || enrollment(t, m, newPhone, window.Secret).Code != 410 {
		t.Fatal("old pending enrollment survived reset")
	}
	m = testManager(t, storage)
	if m.HostKey() != hostKey || len(m.Devices()) != 0 {
		t.Fatal("reset did not survive restart")
	}
	for _, key := range oldKeys {
		if m.Allowed(key) {
			t.Fatal("old approval survived restart")
		}
	}
	// Consumed receipts are removed with grants; none can silently re-enroll.
	for index, invitation := range invitations {
		if enrollment(t, m, oldPhones[index], invitation.Secret).Code != 410 {
			t.Fatal("consumed invitation survived bulk reset")
		}
	}
	approve(t, m, newPhone)
	if !m.Allowed(keyOf(newPhone)) || len(m.Devices()) != 1 {
		t.Fatal("fresh explicit approval could not reuse freed capacity")
	}
}

func TestRevokeAllWithNoGrantsStillClosesPendingEnrollment(t *testing.T) {
	storage := &memoryStore{}
	m := testManager(t, storage)
	phone := testCertificate(t, true)
	window, _ := m.Open("192.168.1.2", 9844)
	enrollment(t, m, phone, window.Secret)
	id := m.pending.ID
	for range 2 {
		if count, err := m.RevokeAll(); err != nil || count != 0 {
			t.Fatal("empty reset was not repeatable", count, err)
		}
	}
	if !errors.Is(m.Approve(id), ErrRequest) || enrollment(t, m, phone, window.Secret).Code != 410 ||
		len(testManager(t, storage).Devices()) != 0 || !bytes.Contains(storage.data, []byte(`"grants":[]`)) {
		t.Fatal("empty reset left enrollment open or wrote invalid state")
	}
}

func TestRevokeAllPersistenceFailureDisablesEveryApproval(t *testing.T) {
	storage := &memoryStore{}
	m := testManager(t, storage)
	first, second := testCertificate(t, true), testCertificate(t, true)
	approve(t, m, first)
	approve(t, m, second)
	previous := append([]byte(nil), storage.data...)
	window, _ := m.Open("192.168.1.2", 9844)
	enrollment(t, m, first, window.Secret)
	id := m.pending.ID
	storage.fail = true
	if count, err := m.RevokeAll(); !errors.Is(err, ErrState) || count != 0 {
		t.Fatal("failed reset claimed success", count, err)
	}
	if m.Allowed(keyOf(first)) || m.Allowed(keyOf(second)) || !bytes.Equal(previous, storage.data) ||
		m.Approve(id) == nil || enrollment(t, m, first, window.Secret).Code != 503 {
		t.Fatal("failed reset left authorization open or claimed persisted removal")
	}
	if _, err := m.Open("192.168.1.2", 9844); !errors.Is(err, ErrState) {
		t.Fatal("failed reset reopened enrollment", err)
	}
}
