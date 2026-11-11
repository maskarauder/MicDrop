package main

import (
	"bufio"
	"context"
	"crypto/tls"
	"fmt"
	"io"
	"net"
	"strings"
	"sync"
	"time"

	"github.com/maskarauder/MicDrop/internal/identity"
	"github.com/maskarauder/MicDrop/internal/pairing"
	"github.com/maskarauder/MicDrop/internal/session"
	qrcode "github.com/skip2/go-qrcode"
)

func openPairedStream(ip net.IP, directory string, stdout io.Writer, observers ...func(pairing.Pending)) (*pairing.Manager, *tls.Config, io.Closer, error) {
	var err error
	if directory == "" {
		directory, err = identity.DefaultDirectory()
	}
	if err != nil {
		return nil, nil, nil, err
	}
	store, err := identity.NewStore(directory)
	if err != nil {
		return nil, nil, nil, err
	}
	host, _, err := store.Ensure()
	if err != nil {
		return nil, nil, nil, err
	}
	grants, err := store.OpenPairing()
	if err != nil {
		return nil, nil, nil, err
	}
	manager, err := pairing.New(grants, host.Info().Fingerprint, func(p pairing.Pending) {
		if len(observers) > 0 && observers[0] != nil {
			observers[0](p)
			return
		}
		fmt.Fprintf(stdout, "\nPair request %s from %s (device name is unverified).\nPhone key: %s\nCompare the request ID on Android, then enter: approve %s\nOr enter: reject %s\n", p.ID, p.Label, p.Fingerprint, p.ID, p.ID)
	})
	if err != nil {
		grants.Close()
		return nil, nil, nil, err
	}
	certificate, err := host.Certificate(ip, time.Now())
	if err != nil {
		grants.Close()
		return nil, nil, nil, err
	}
	var certificateMu sync.Mutex
	config := manager.TLSConfig(func(*tls.ClientHelloInfo) (*tls.Certificate, error) {
		certificateMu.Lock()
		defer certificateMu.Unlock()
		now := time.Now()
		if now.Before(certificate.Leaf.NotBefore) || !now.Add(time.Hour).Before(certificate.Leaf.NotAfter) {
			renewed, err := host.Certificate(ip, now)
			if err != nil {
				return nil, err
			}
			certificate = renewed // Same SPKI; a running listener can outlive 24 hours.
		}
		current := certificate
		return &current, nil
	})
	fmt.Fprintln(stdout, "Paired host key:", host.Info().Fingerprint)
	return manager, config, grants, nil
}

func printPairing(manager *pairing.Manager, host string, port int, stdout io.Writer, formatters ...func(string) string) error {
	i, err := manager.Open(host, port)
	if err != nil {
		return err
	}
	// Keep the invitation and QR together even if an existing session ends while
	// printing. The normal output writer serializes this one complete write.
	var out strings.Builder
	link := i.Link()
	if len(formatters) > 0 && formatters[0] != nil {
		link = formatters[0](link)
	}
	fmt.Fprintln(&out, "Private, single-use pairing invitation (paste into Android and tap Connect):")
	fmt.Fprintln(&out, link)
	qr, columns, err := pairingQR(link)
	if err == nil {
		fmt.Fprintf(&out, "\nOr tap Scan pairing QR in Android, then Connect. Keep the entire code visible.\nMaximize this console: the code needs %d columns. Do not share it.\n", columns)
		out.WriteString(qr)
	} else {
		// QR is a convenience; failure must not hide or invalidate the manual link.
		fmt.Fprintln(&out, "QR unavailable. Paste the invitation above instead.")
	}
	fmt.Fprintln(&out, "Approval window expires:", time.Unix(i.ExpiresAt, 0).Format(time.RFC3339))
	_, err = io.WriteString(stdout, out.String())
	return err
}

func pairingQR(link string) (string, int, error) {
	// Low ECC keeps the current invitation below 80 terminal columns, including
	// its four-module quiet zone. Half-block glyphs pack two rows into one line.
	// Android scans both polarities so light and dark console themes work.
	code, err := qrcode.New(link, qrcode.Low)
	if err != nil {
		return "", 0, err
	}
	return code.ToSmallString(false), len(code.Bitmap()), nil
}

// Stdin belongs to this CLI process. A blocked read never delays shutdown;
// main exits the process after closing media, HTTP and the state-file lock.
func pairingCommands(ctx context.Context, input io.Reader) <-chan string {
	commands := make(chan string)
	go func() {
		defer close(commands)
		scanner := bufio.NewScanner(input)
		scanner.Buffer(make([]byte, 256), 256)
		for scanner.Scan() {
			select {
			case commands <- scanner.Text():
			case <-ctx.Done():
				return
			}
		}
	}()
	return commands
}

const pairingHelp = "Commands: pair | approve <request-id> | reject <request-id> | devices | revoke <full-phone-key> | revoke-all | quit"

func revokeAllPairings(manager *pairing.Manager, control *session.Host, stdout io.Writer) error {
	devices := manager.Devices()
	count, err := manager.RevokeAll()
	if control != nil {
		// A persistence error disables all authorization in this manager too.
		// Stop existing media in either case; an initializing factory rechecks
		// authorization before publishing its offer.
		for _, device := range devices {
			control.Revoke(device.Fingerprint)
		}
	}
	if err == nil {
		fmt.Fprintf(stdout, "Paired phones removed: %d. Pairing window closed. Enter pair to approve a phone again.\n", count)
	}
	return err
}

func pairingCommand(line string, manager *pairing.Manager, control *session.Host, host string, port int, stdout, stderr io.Writer, formatters ...func(string) string) bool {
	args := strings.Fields(line)
	if len(args) == 0 {
		return false
	}
	var err error
	switch {
	case len(args) == 1 && args[0] == "quit":
		return true
	case len(args) == 1 && args[0] == "pair":
		err = printPairing(manager, host, port, stdout, formatters...)
	case len(args) == 2 && args[0] == "approve":
		err = manager.Approve(args[1])
		if err == nil {
			fmt.Fprintln(stdout, "Phone approved. Android connects after pairing if setup is still open; otherwise tap Reconnect.")
		}
	case len(args) == 2 && args[0] == "reject":
		err = manager.Reject(args[1])
		if err == nil {
			fmt.Fprintln(stdout, "Request rejected; pairing window closed.")
		}
	case len(args) == 1 && args[0] == "devices":
		devices := manager.Devices()
		if len(devices) == 0 {
			fmt.Fprintln(stdout, "No paired phones.")
		}
		for _, d := range devices {
			fmt.Fprintf(stdout, "%s  %s  playback\n", d.Fingerprint, d.Label)
		}
	case len(args) == 2 && args[0] == "revoke":
		err = manager.Revoke(args[1])
		// Also run on a persistence error: the manager fails closed in memory.
		control.Revoke(args[1])
		if err == nil {
			fmt.Fprintln(stdout, "Phone revoked. Its active stream is stopping; pairing window closed.")
		}
	case len(args) == 1 && args[0] == "revoke-all":
		err = revokeAllPairings(manager, control, stdout)
	default:
		fmt.Fprintln(stdout, pairingHelp)
	}
	if err != nil {
		fmt.Fprintln(stderr, err)
	}
	return false
}
