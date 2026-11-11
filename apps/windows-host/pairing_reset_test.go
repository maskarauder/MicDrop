package main

import (
	"bytes"
	"encoding/json"
	"errors"
	"io"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"runtime"
	"strings"
	"sync/atomic"
	"testing"
	"time"

	"github.com/maskarauder/MicDrop/internal/diagnostics"
	"github.com/maskarauder/MicDrop/internal/identity"
	"github.com/maskarauder/MicDrop/internal/pairing"
	"github.com/maskarauder/MicDrop/internal/rtc"
	"github.com/maskarauder/MicDrop/internal/session"
)

type resetTestStore struct {
	data  []byte
	fail  bool
	saves int
}

func (s *resetTestStore) Load() ([]byte, error) { return append([]byte(nil), s.data...), nil }
func (s *resetTestStore) Save(data []byte) error {
	s.saves++
	if s.fail {
		return errors.New("disk failed")
	}
	s.data = append([]byte(nil), data...)
	return nil
}

func resetTestState(hostKey string, keys ...string) []byte {
	grants := []pairing.Grant{}
	for _, key := range keys {
		grants = append(grants, pairing.Grant{Fingerprint: key, Label: "Test phone", ApprovedAt: 1, Receipt: strings.Repeat("c", 64)})
	}
	data, _ := json.Marshal(struct {
		Version int             `json:"version"`
		Host    string          `json:"host_key"`
		Grants  []pairing.Grant `json:"grants"`
	}{1, hostKey, grants})
	return data
}

func resetTestManager(t *testing.T, storage pairing.Storage) *pairing.Manager {
	t.Helper()
	manager, err := pairing.New(storage, strings.Repeat("a", 64), nil)
	if err != nil {
		t.Fatal(err)
	}
	return manager
}

// TLS key proof is covered in pairing's contracts. This authority tests the
// CLI-to-session teardown against the real manager's current approval list.
type resetTestAuthority struct{ manager *pairing.Manager }

func (a resetTestAuthority) Client(r *http.Request) (string, bool) {
	key := r.Header.Get("X-Test-Key")
	return key, a.manager.Allowed(key)
}
func (a resetTestAuthority) Allowed(key string) bool { return a.manager.Allowed(key) }
func (a resetTestAuthority) Enrollment(w http.ResponseWriter, r *http.Request) {
	a.manager.Enrollment(w, r)
}

type resetTestPeer struct{ closed atomic.Bool }

func (*resetTestPeer) Offer() (string, error) { return "offer", nil }
func (*resetTestPeer) Answer(string) error    { return nil }
func (*resetTestPeer) Status() (rtc.Status, error) {
	return rtc.Status{State: "connected", Opus: true}, nil
}
func (p *resetTestPeer) Close() { p.closed.Store(true) }

func resetTestOffer(host *session.Host, key string) *httptest.ResponseRecorder {
	r := httptest.NewRequest("POST", "https://192.168.1.2/offer", strings.NewReader(`{"version":3}`))
	r.Header.Set("X-Test-Key", key)
	w := httptest.NewRecorder()
	host.ServeHTTP(w, r)
	return w
}

func TestConsoleRevokeAllEndsActiveSessionAndFinalizesLog(t *testing.T) {
	for _, fail := range []bool{false, true} {
		t.Run(map[bool]string{false: "persisted", true: "save_failed"}[fail], func(t *testing.T) {
			first, second := strings.Repeat("b", 64), strings.Repeat("d", 64)
			store := &resetTestStore{data: resetTestState(strings.Repeat("a", 64), first, second), fail: fail}
			manager := resetTestManager(t, store)
			log, path, err := diagnostics.CreateInDirectory(t.TempDir(), diagnostics.DesktopCapture, time.Now())
			if err != nil {
				t.Fatal(err)
			}
			peer, ended := &resetTestPeer{}, make(chan string, 1)
			host, err := session.NewPairedHost(resetTestAuthority{manager}, func(time.Time, session.OfferOptions) (session.Resources, error) {
				return session.Resources{Peer: peer, Log: log, End: func(reason string, _ error, _ *rtc.Status) { ended <- reason }}, nil
			})
			if err != nil {
				t.Fatal(err)
			}
			defer host.Close("test_complete")
			if response := resetTestOffer(host, first); response.Code != 200 {
				t.Fatal(response.Code, response.Body.String())
			}
			var output, stderr bytes.Buffer
			if pairingCommand("revoke-all", manager, host, "192.168.1.2", 9844, &output, &stderr) {
				t.Fatal("bulk revocation quit the listener")
			}
			select {
			case reason := <-ended:
				if reason != "device_revoked" || !peer.closed.Load() {
					t.Fatal("media was not revoked", reason)
				}
			case <-time.After(time.Second):
				t.Fatal("bulk revocation left media running")
			}
			data, err := os.ReadFile(path)
			if err != nil || !bytes.Contains(data, []byte(`"reason":"device_revoked"`)) || !bytes.Contains(data, []byte(`"type":"session_end"`)) {
				t.Fatal("combined log was not finalized", err)
			}
			if manager.Allowed(first) || manager.Allowed(second) || resetTestOffer(host, first).Code != 403 {
				t.Fatal("an old phone still has access")
			}
			if fail {
				if output.Len() != 0 || stderr.Len() == 0 {
					t.Fatal("persistence failure claimed success")
				}
			} else {
				if stderr.Len() != 0 || !strings.Contains(output.String(), "Paired phones removed: 2") || len(resetTestManager(t, store).Devices()) != 0 {
					t.Fatal("reset did not report/persist its result", output.String(), stderr.String())
				}
				output.Reset()
				pairingCommand("pair", manager, host, "192.168.1.2", 9844, &output, &stderr)
				if stderr.Len() != 0 || !strings.Contains(output.String(), "micdrop://pair/v1/") {
					t.Fatal("listener could not open fresh pairing")
				}
			}
		})
	}
}

func TestRevokeAllDuringInitializationCannotPublishAnOldApproval(t *testing.T) {
	key := strings.Repeat("b", 64)
	store := &resetTestStore{data: resetTestState(strings.Repeat("a", 64), key)}
	manager := resetTestManager(t, store)
	entered, release, ended := make(chan struct{}), make(chan struct{}), make(chan string, 1)
	peer := &resetTestPeer{}
	host, err := session.NewPairedHost(resetTestAuthority{manager}, func(time.Time, session.OfferOptions) (session.Resources, error) {
		close(entered)
		<-release
		return session.Resources{Peer: peer, End: func(reason string, _ error, _ *rtc.Status) { ended <- reason }}, nil
	})
	if err != nil {
		t.Fatal(err)
	}
	defer host.Close("test_complete")
	response := make(chan *httptest.ResponseRecorder, 1)
	go func() { response <- resetTestOffer(host, key) }()
	<-entered
	err = revokeAllPairings(manager, host, io.Discard)
	close(release)
	if err != nil {
		t.Fatal(err)
	}
	if result := <-response; result.Code != 403 {
		t.Fatal("initializing revoked phone received an offer", result.Code)
	}
	if reason := <-ended; reason != "device_revoked" || !peer.closed.Load() {
		t.Fatal("initializing media was not revoked", reason)
	}
}

func TestConsoleRevokeAllRejectsExtraArgumentsWithoutChangingApprovals(t *testing.T) {
	key := strings.Repeat("b", 64)
	store := &resetTestStore{data: resetTestState(strings.Repeat("a", 64), key)}
	manager := resetTestManager(t, store)
	for _, command := range []string{"revoke-all extra", "revoke-all --pair"} {
		pairingCommand(command, manager, nil, "192.168.1.2", 9844, io.Discard, io.Discard)
	}
	if store.saves != 0 || !manager.Allowed(key) {
		t.Fatal("malformed bulk command removed approval")
	}
}

func TestWindowsBulkRevocationPreservesProtectedHostIdentity(t *testing.T) {
	if runtime.GOOS != "windows" && runtime.GOOS != "linux" && runtime.GOOS != "darwin" {
		t.Skip("requires protected host identity and exclusive pairing lock")
	}
	directory := t.TempDir()
	store, err := identity.NewStore(directory)
	if err != nil {
		t.Fatal(err)
	}
	host, _, err := store.Ensure()
	if err != nil {
		t.Fatal(err)
	}
	fingerprint := host.Info().Fingerprint
	identityBefore, err := os.ReadFile(filepath.Join(directory, identity.Filename))
	if err != nil {
		t.Fatal(err)
	}
	func() {
		grants, err := store.OpenPairing()
		if err != nil {
			t.Fatal(err)
		}
		defer func() {
			if err := grants.Close(); err != nil {
				t.Error(err)
			}
		}()
		if err := grants.Save(resetTestState(fingerprint, strings.Repeat("b", 64))); err != nil {
			t.Fatal(err)
		}
		manager, err := pairing.New(grants, fingerprint, nil)
		if err != nil {
			t.Fatal(err)
		}
		if err := revokeAllPairings(manager, nil, io.Discard); err != nil {
			t.Fatal(err)
		}
	}()
	reopened, err := store.OpenPairing()
	if err != nil {
		t.Fatal(err)
	}
	defer reopened.Close()
	manager, err := pairing.New(reopened, fingerprint, nil)
	if err != nil || len(manager.Devices()) != 0 {
		t.Fatal("protected approvals did not stay cleared", err)
	}
	identityAfter, err := os.ReadFile(filepath.Join(directory, identity.Filename))
	if err != nil || !bytes.Equal(identityBefore, identityAfter) || manager.HostKey() != fingerprint {
		t.Fatal("bulk revocation changed the protected host identity", err)
	}
}
