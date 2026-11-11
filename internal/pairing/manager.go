// Package pairing authorizes TLS-proven P-256 identities for playback only.
// Enrollment secrets open a local approval request; they never grant playback.
package pairing

import (
	"bytes"
	"crypto/rand"
	"crypto/sha256"
	"crypto/subtle"
	"encoding/base64"
	"encoding/hex"
	"encoding/json"
	"errors"
	"io"
	"net"
	"net/http"
	"os"
	"regexp"
	"sync"
	"time"
)

const MaxDevices = 16

var ErrState = errors.New("pairing state unavailable; stop the host and check protected state")
var ErrRequest = errors.New("no matching live pairing request")
var pinPattern = regexp.MustCompile(`^[0-9a-f]{64}$`)
var labelPattern = regexp.MustCompile(`^[A-Za-z0-9 ._()-]{1,64}$`)
var secretPattern = regexp.MustCompile(`^[A-Za-z0-9_-]{43}$`)

type Storage interface {
	Load() ([]byte, error)
	Save([]byte) error
}
type Grant struct {
	Fingerprint string `json:"client_key"`
	Label       string `json:"label"`
	ApprovedAt  int64  `json:"approved_at"`
	Receipt     string `json:"receipt"` // SHA-256 of consumed invitation, bound to this key.
}
type state struct {
	Version int     `json:"version"`
	Host    string  `json:"host_key"`
	Grants  []Grant `json:"grants"`
}
type Invitation struct {
	Host      string `json:"host"`
	Port      int    `json:"port"`
	HostKey   string `json:"host_key"`
	Secret    string `json:"secret"`
	ExpiresAt int64  `json:"expires_at"`
}

func (i Invitation) Link() string {
	b, _ := json.Marshal(i)
	return "micdrop://pair/v1/" + base64.RawURLEncoding.EncodeToString(b)
}

type Pending struct{ ID, Fingerprint, Label string }
type Manager struct {
	mu        sync.Mutex
	store     Storage
	state     state
	window    *Invitation
	pending   *Pending
	broken    bool
	now       func() time.Time
	onPending func(Pending)
}

// HostKey is public metadata. Discovery must never receive the window secret.
func (m *Manager) HostKey() string {
	m.mu.Lock()
	defer m.mu.Unlock()
	return m.state.Host
}

func New(store Storage, hostKey string, onPending func(Pending)) (*Manager, error) {
	if !pinPattern.MatchString(hostKey) {
		return nil, ErrState
	}
	m := &Manager{store: store, state: state{1, hostKey, []Grant{}}, now: time.Now, onPending: onPending}
	b, err := store.Load()
	defer clear(b)
	if errors.Is(err, os.ErrNotExist) {
		return m, nil
	}
	if err != nil {
		return nil, ErrState
	}
	var value state
	d := json.NewDecoder(bytes.NewReader(b))
	d.DisallowUnknownFields()
	if d.Decode(&value) != nil || d.Decode(new(any)) != io.EOF || value.Version != 1 || value.Host != hostKey || value.Grants == nil || len(value.Grants) > MaxDevices {
		return nil, ErrState
	}
	seen := map[string]bool{}
	for _, g := range value.Grants {
		if !pinPattern.MatchString(g.Fingerprint) || !pinPattern.MatchString(g.Receipt) || !labelPattern.MatchString(g.Label) || g.ApprovedAt <= 0 || g.ApprovedAt > 253402300799 || seen[g.Fingerprint] {
			return nil, ErrState
		}
		seen[g.Fingerprint] = true
	}
	canonical, _ := json.Marshal(value)
	if !bytes.Equal(canonical, b) {
		return nil, ErrState
	}
	m.state = value
	return m, nil
}

func (m *Manager) Open(host string, port int) (Invitation, error) {
	m.mu.Lock()
	defer m.mu.Unlock()
	ip := net.ParseIP(host)
	if m.broken || ip == nil || ip.To4() == nil || !ip.IsPrivate() || port < 1 || port > 65535 {
		return Invitation{}, ErrState
	}
	var secret [32]byte
	if _, err := rand.Read(secret[:]); err != nil {
		return Invitation{}, ErrState
	}
	i := Invitation{ip.String(), port, m.state.Host, base64.RawURLEncoding.EncodeToString(secret[:]), m.now().Add(5 * time.Minute).Unix()}
	m.window, m.pending = &i, nil
	return i, nil
}

func (m *Manager) Allowed(key string) bool {
	m.mu.Lock()
	defer m.mu.Unlock()
	if m.broken || key == "" {
		return false
	}
	for _, g := range m.state.Grants {
		if g.Fingerprint == key {
			return true
		}
	}
	return false
}
func (m *Manager) Devices() []Grant {
	m.mu.Lock()
	defer m.mu.Unlock()
	return append([]Grant(nil), m.state.Grants...)
}
func (m *Manager) save(grants []Grant) error {
	next := state{1, m.state.Host, grants}
	b, err := json.Marshal(next)
	if err != nil || m.store.Save(b) != nil {
		m.broken = true
		return ErrState
	}
	m.state = next
	return nil
}
func (m *Manager) live() bool {
	return !m.broken && m.window != nil && m.now().Unix() < m.window.ExpiresAt
}
func (m *Manager) Approve(id string) error {
	m.mu.Lock()
	defer m.mu.Unlock()
	if !m.live() || m.pending == nil || m.pending.ID != id {
		return ErrRequest
	}
	p := m.pending
	grants := append([]Grant{}, m.state.Grants...)
	grant := Grant{p.Fingerprint, p.Label, m.now().Unix(), digest(m.window.Secret)}
	found := false
	for i := range grants {
		if grants[i].Fingerprint == p.Fingerprint {
			grants[i] = grant
			found = true
		}
	}
	if !found {
		if len(grants) >= MaxDevices {
			return errors.New("device limit reached; use devices and revoke <full-phone-key>, or revoke-all to remove all phones")
		}
		grants = append(grants, grant)
	}
	if err := m.save(grants); err != nil {
		return err
	}
	// Receipt and grant are one durable record. A replay can only acknowledge
	// this same TLS-proven key, including after restart or a lost response.
	m.window, m.pending = nil, nil
	return nil
}
func (m *Manager) Reject(id string) error {
	m.mu.Lock()
	defer m.mu.Unlock()
	if m.pending == nil || m.pending.ID != id {
		return ErrRequest
	}
	m.window, m.pending = nil, nil // Rejection burns the entire window.
	return nil
}
func (m *Manager) Revoke(key string) error {
	m.mu.Lock()
	defer m.mu.Unlock()
	if m.broken {
		return ErrState
	}
	grants := make([]Grant, 0, len(m.state.Grants))
	found := false
	for _, g := range m.state.Grants {
		if g.Fingerprint == key {
			found = true
		} else {
			grants = append(grants, g)
		}
	}
	if !found {
		return errors.New("paired device not found; use the full fingerprint from devices")
	}
	if err := m.save(grants); err != nil {
		return err
	}
	// A revoked phone cannot re-enroll with an already open invitation.
	m.window, m.pending = nil, nil
	return nil
}

// RevokeAll replaces the grant list in one durable operation while retaining
// the host identity. Close enrollment too, even when there are no grants: an
// old invitation or pending approval must not undo the local reset.
func (m *Manager) RevokeAll() (int, error) {
	m.mu.Lock()
	defer m.mu.Unlock()
	if m.broken {
		return 0, ErrState
	}
	count := len(m.state.Grants)
	m.window, m.pending = nil, nil
	if err := m.save([]Grant{}); err != nil {
		return 0, err // save also disables live authorization on failure.
	}
	return count, nil
}

func digest(secret string) string {
	sum := sha256.Sum256([]byte(secret))
	return hex.EncodeToString(sum[:])
}

// Enrollment is called behind the listener's TLS, concurrency and rate guards.
func (m *Manager) Enrollment(w http.ResponseWriter, r *http.Request) {
	key, err := ClientKey(r.TLS, m.now())
	if err != nil {
		http.Error(w, "Client identity required", 403)
		return
	}
	if r.Method != http.MethodPost || r.Header.Get("Authorization") != "" {
		http.Error(w, "Invalid enrollment request", 400)
		return
	}
	var req struct {
		Version int    `json:"version"`
		Secret  string `json:"secret"`
		Label   string `json:"label"`
	}
	d := json.NewDecoder(http.MaxBytesReader(w, r.Body, 1024))
	d.DisallowUnknownFields()
	if d.Decode(&req) != nil || d.Decode(new(any)) != io.EOF || req.Version != 1 || !secretPattern.MatchString(req.Secret) || !labelPattern.MatchString(req.Label) {
		http.Error(w, "Invalid enrollment request", 400)
		return
	}
	m.mu.Lock()
	defer m.mu.Unlock()
	if m.broken {
		http.Error(w, "Pairing unavailable", 503)
		return
	}
	for _, g := range m.state.Grants {
		if g.Fingerprint == key && subtle.ConstantTimeCompare([]byte(g.Receipt), []byte(digest(req.Secret))) == 1 {
			pairResponse(w, "approved", "")
			return
		}
	}
	if !m.live() || subtle.ConstantTimeCompare([]byte(req.Secret), []byte(m.window.Secret)) != 1 {
		http.Error(w, "Enrollment unavailable", 410)
		return
	}
	if m.pending != nil && m.pending.Fingerprint != key {
		http.Error(w, "Another request awaits approval", 409)
		return
	}
	if m.pending == nil {
		var id [6]byte
		if _, err := rand.Read(id[:]); err != nil {
			http.Error(w, "Pairing unavailable", 503)
			return
		}
		m.pending = &Pending{hex.EncodeToString(id[:]), key, req.Label}
		if m.onPending != nil {
			m.onPending(*m.pending)
		}
	}
	pairResponse(w, "pending", m.pending.ID)
}
func pairResponse(w http.ResponseWriter, state, id string) {
	w.Header().Set("Content-Type", "application/json")
	_ = json.NewEncoder(w).Encode(struct {
		Version   int    `json:"version"`
		State     string `json:"state"`
		RequestID string `json:"request_id"`
	}{1, state, id})
}
