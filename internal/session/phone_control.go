package session

import (
	"encoding/json"
	"errors"
	"net/http"
	"time"

	"github.com/maskarauder/MicDrop/internal/diagnostics"
	"github.com/maskarauder/MicDrop/internal/phonecontrol"
)

func readPhoneControl(r *http.Request, version int) (bool, bool) {
	values := r.Header.Values(phonecontrol.Header)
	if len(values) == 0 {
		return false, true
	}
	return true, version == 3 && len(values) == 1 && values[0] == "1"
}

// PhoneStatus is an isolated view for desktop presentation. The report's
// counters are not physical audio latency and remain separate from log storage.
type PhoneStatus struct {
	Client            string
	Session           uint64
	Control           *phonecontrol.Snapshot
	ControlNegotiated bool // The /offer capability; known before the first snapshot.
	Pending           bool
	Message           string
	Report            *diagnostics.AndroidReport
	ReportAt          time.Time
	UpdatedAt         time.Time
}

func clonePhoneReport(report *diagnostics.AndroidReport) *diagnostics.AndroidReport {
	if report == nil {
		return nil
	}
	// Validated reports contain only bounded JSON data. Copy all nested maps and
	// pointers so a UI consumer cannot race with request processing or mutate it.
	data, err := json.Marshal(report)
	if err != nil {
		return nil
	}
	var result diagnostics.AndroidReport
	if json.Unmarshal(data, &result) != nil {
		return nil
	}
	return &result
}

func (h *Host) PhoneStatus() *PhoneStatus {
	h.mu.Lock()
	current := h.active
	if h.closed != "" || current == nil || current.server == nil {
		h.mu.Unlock()
		return nil
	}
	s, client, sessionID := current.server, current.client, current.resources.ID
	h.mu.Unlock()
	if h.authority != nil && !h.authority.Allowed(client) {
		return nil
	}
	s.mu.Lock()
	defer s.mu.Unlock()
	if s.stopped {
		return nil
	}
	control, pending, message := s.phoneSettings.View(s.now())
	return &PhoneStatus{Client: client, Session: sessionID, Control: control, ControlNegotiated: s.phoneControl, Pending: pending, Message: message,
		Report: clonePhoneReport(s.phoneReport), ReportAt: s.phoneReportAt, UpdatedAt: s.lastSeen}
}

// QueuePhoneSettings targets an authenticated identity and the current media
// session. No command is retained by Host or carried into a later connection.
func (h *Host) QueuePhoneSettings(client string, sessionID uint64, edit phonecontrol.Edit) (string, error) {
	h.mu.Lock()
	current := h.active
	if h.authority == nil || client == "" || sessionID == 0 || h.closed != "" || current == nil || current.server == nil || current.client != client || current.resources.ID != sessionID {
		h.mu.Unlock()
		return "", errors.New("that phone is not currently connected")
	}
	s := current.server
	h.mu.Unlock()
	if !h.authority.Allowed(client) {
		return "", errors.New("that phone is no longer approved")
	}
	s.mu.Lock()
	defer s.mu.Unlock()
	if !s.phoneControl || !s.answered || s.stopped || s.now().Sub(s.lastSeen) > s.heartbeatLimit() {
		return "", errors.New("phone settings are unavailable; connect an updated phone app")
	}
	return s.phoneSettings.Queue(edit, s.now())
}
