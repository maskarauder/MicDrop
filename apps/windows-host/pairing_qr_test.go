package main

import (
	"bytes"
	"encoding/base64"
	"encoding/json"
	"os"
	"strings"
	"testing"
	"unicode/utf8"

	"github.com/maskarauder/MicDrop/internal/pairing"
)

// Android's independent ZXing decoder consumes this exact terminal fixture.
// Its public test values are synthetic and never authorize a running host.
func TestPairingQRTerminalFixture(t *testing.T) {
	b, err := os.ReadFile("testdata/pairing-qr.txt")
	if err != nil {
		t.Fatal(err)
	}
	link, expected, ok := strings.Cut(strings.ReplaceAll(string(b), "\r\n", "\n"), "\n")
	if !ok {
		t.Fatal("missing fixture payload")
	}
	got, width, err := pairingQR(link)
	if err != nil || got != expected {
		t.Fatal("terminal output no longer matches the Android interoperability fixture", err)
	}
	if width > 80 {
		t.Fatal("QR wraps in an 80-column terminal", width)
	}
	for _, line := range strings.Split(strings.TrimSuffix(got, "\n"), "\n") {
		if utf8.RuneCountInString(line) != width {
			t.Fatal("inconsistent terminal width")
		}
	}
	// Include the protocol's longest private IPv4, port and accepted timestamp.
	invitation := pairing.Invitation{Host: "192.168.255.255", Port: 65535,
		HostKey: strings.Repeat("a", 64), Secret: strings.Repeat("s", 43), ExpiresAt: 253402300799}
	if _, columns, err := pairingQR(invitation.Link()); err != nil || columns > 80 {
		t.Fatalf("maximum invitation: columns=%d, error=%v", columns, err)
	}
}

type qrTestStore struct{ saves int }

func (*qrTestStore) Load() ([]byte, error) { return nil, os.ErrNotExist }
func (s *qrTestStore) Save([]byte) error   { s.saves++; return nil }

type qrTestWriter struct {
	bytes.Buffer
	writes int
}

func (w *qrTestWriter) Write(b []byte) (int, error) { w.writes++; return w.Buffer.Write(b) }
func (w *qrTestWriter) WriteString(s string) (int, error) {
	w.writes++
	return w.Buffer.WriteString(s)
}

func TestPairingPrintsOneInvitationAndMatchingQRWithoutApproval(t *testing.T) {
	store := &qrTestStore{}
	manager, err := pairing.New(store, strings.Repeat("a", 64), nil)
	if err != nil {
		t.Fatal(err)
	}
	previous := ""
	for range 2 {
		var output qrTestWriter
		if err := printPairing(manager, "192.168.1.20", 9844, &output); err != nil {
			t.Fatal(err)
		}
		if output.writes != 1 {
			t.Fatal("session messages can interleave with the QR")
		}
		link := strings.Split(output.String(), "\n")[1]
		if link == previous {
			t.Fatal("pair must open a fresh window")
		}
		previous = link
		data, err := base64.RawURLEncoding.DecodeString(strings.TrimPrefix(link, "micdrop://pair/v1/"))
		if err != nil {
			t.Fatal(err)
		}
		var invitation pairing.Invitation
		if err := json.Unmarshal(data, &invitation); err != nil || invitation.Host != "192.168.1.20" {
			t.Fatal("missing manual invitation", err)
		}
		qr, _, err := pairingQR(link)
		if err != nil || !strings.Contains(output.String(), qr) {
			t.Fatal("manual and QR invitations differ", err)
		}
	}
	if len(manager.Devices()) != 0 || store.saves != 0 {
		t.Fatal("displaying an invitation must not approve a phone")
	}
}
