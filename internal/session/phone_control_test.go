package session

import (
	"encoding/json"
	"net/http/httptest"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"

	"github.com/maskarauder/MicDrop/internal/diagnostics"
	"github.com/maskarauder/MicDrop/internal/phonecontrol"
	"github.com/maskarauder/MicDrop/internal/rtc"
)

func settingsSnapshot() *phonecontrol.Snapshot {
	return &phonecontrol.Snapshot{Version: 1, Revision: strings.Repeat("a", 64), Enabled: true,
		Fields: []phonecontrol.Field{{Key: "audio.fast_recovery", Label: "Private phone setting", Group: "Audio", Kind: "bool", Value: json.RawMessage("true"), Effect: "next_connection"}}}
}

func settingsEdit(snapshot *phonecontrol.Snapshot) phonecontrol.Edit {
	return phonecontrol.Edit{BaseRevision: snapshot.Revision, Changes: map[string]json.RawMessage{"audio.fast_recovery": json.RawMessage("false")}}
}

func phoneControlHost(t *testing.T, logger *diagnostics.Log) (*Host, *time.Time, *recoveryAuthority) {
	t.Helper()
	now := time.Now()
	authority := &recoveryAuthority{}
	var generation uint64
	h, err := NewPairedHost(authority, func(time.Time, OfferOptions) (Resources, error) {
		generation++
		return Resources{ID: generation, Peer: &cyclePeer{fakePeer: fakePeer{status: rtc.Status{State: "connected"}}}, Log: logger}, nil
	})
	if err != nil {
		t.Fatal(err)
	}
	h.now = func() time.Time { return now }
	t.Cleanup(func() { h.Close("test") })
	return h, &now, authority
}

func phoneControlClaim(t *testing.T, h *Host, client string, enabled bool) (string, *managedSession) {
	t.Helper()
	r := httptest.NewRequest("POST", "https://paired.test/offer", strings.NewReader(`{"version":3}`))
	r.Header.Set("X-Test-Verified-Identity", client)
	if enabled {
		r.Header.Set(phonecontrol.Header, "1")
	}
	w := httptest.NewRecorder()
	h.ServeHTTP(w, r)
	var offer struct {
		Session      string `json:"session"`
		PhoneControl int    `json:"phone_control_version"`
		Diagnostics  int    `json:"diagnostics_version"`
	}
	if w.Code != 200 || json.Unmarshal(w.Body.Bytes(), &offer) != nil || (offer.PhoneControl == 1) != enabled || (enabled && offer.Diagnostics != 1) {
		t.Fatal("offer capability", w.Code, w.Body.String())
	}
	if w := microphoneCall(h, client, "/answer", offer.Session, `{"version":3,"sdp":"answer"}`); w.Code != 200 {
		t.Fatal("answer", w.Code, w.Body.String())
	}
	return offer.Session, h.active
}

func settingsBody(snapshot *phonecontrol.Snapshot) string {
	encoded, _ := json.Marshal(map[string]any{"version": 3, "phone_control": snapshot})
	return string(encoded)
}

func TestPhoneControlRequiresNegotiationAndAuthenticatedOwner(t *testing.T) {
	h, _, _ := phoneControlHost(t, nil)
	token, current := phoneControlClaim(t, h, "phone", false)
	snapshot := settingsSnapshot()
	if w := microphoneCall(h, "phone", "/status", token, settingsBody(snapshot)); w.Code != 400 {
		t.Fatal("unnegotiated snapshot accepted", w.Code, w.Body.String())
	}
	if _, err := h.QueuePhoneSettings("phone", 1, settingsEdit(snapshot)); err == nil {
		t.Fatal("unnegotiated edit accepted")
	}
	// Windows asks an older phone for an update instead of a reconnect.
	if status := h.PhoneStatus(); status == nil || status.ControlNegotiated || status.Control != nil {
		t.Fatal("unnegotiated phone presented as supporting settings", status)
	}
	if w := microphoneCall(h, "phone", "/status", token, `{"version":3,"android":null}`); w.Code != 400 {
		t.Fatal("empty body changed legacy validation")
	}
	microphoneCall(h, "phone", "/stop", token, `{}`)
	waitSession(t, current)
	token, _ = phoneControlClaim(t, h, "phone", true)
	for _, request := range []struct {
		client, token string
		code          int
	}{
		{"unknown", token, 403}, {"other", token, 403}, {"phone", reusableToken, 401},
	} {
		if w := microphoneCall(h, request.client, "/status", request.token, settingsBody(snapshot)); w.Code != request.code {
			t.Fatal("settings bypassed identity/session", w.Code, w.Body.String())
		}
	}
	if status := h.PhoneStatus(); status == nil || status.Control != nil || !status.ControlNegotiated {
		t.Fatal("rejected request changed stored settings, or support waited for a snapshot", status)
	}
	if w := microphoneCall(h, "phone", "/status", token, settingsBody(snapshot)); w.Code != 200 {
		t.Fatal(w.Code, w.Body.String())
	}
	if _, err := h.QueuePhoneSettings("other", 2, settingsEdit(snapshot)); err == nil {
		t.Fatal("desktop targeted different phone")
	}
	if _, err := h.QueuePhoneSettings("phone", 2, phonecontrol.Edit{BaseRevision: strings.Repeat("b", 64), Changes: settingsEdit(snapshot).Changes}); err == nil {
		t.Fatal("stale desktop revision accepted")
	}
}

func TestStaleDesktopCommandCannotReachSamePhoneSuccessor(t *testing.T) {
	h, now, authority := phoneControlHost(t, nil)
	token, first := phoneControlClaim(t, h, "phone", true)
	snapshot := settingsSnapshot()
	microphoneCall(h, "phone", "/status", token, settingsBody(snapshot))
	oldID := h.PhoneStatus().Session
	edit := settingsEdit(snapshot) // A desktop command can wait in the UI queue.
	microphoneCall(h, "phone", "/stop", token, `{}`)
	waitSession(t, first)
	token, current := phoneControlClaim(t, h, "phone", true)
	microphoneCall(h, "phone", "/status", token, settingsBody(snapshot))
	newID := h.PhoneStatus().Session
	if newID == oldID || newID == 0 {
		t.Fatal("fixture did not create a distinct local session generation")
	}
	for _, stale := range []uint64{0, oldID} {
		if _, err := h.QueuePhoneSettings("phone", stale, edit); err == nil {
			t.Fatal("queued desktop edit crossed session boundary", stale)
		}
	}
	if _, err := h.QueuePhoneSettings("phone", newID, edit); err != nil {
		t.Fatal("current session rejected valid edit", err)
	}
	// Reaching the command deadline must stop delivery, even with a healthy
	// session and the same phone/unchanged settings revision.
	*now = now.Add(phonecontrol.CommandTimeout)
	w := microphoneCall(h, "phone", "/status", token, settingsBody(snapshot))
	if w.Code != 200 || strings.Contains(w.Body.String(), "phone_control_command") || h.PhoneStatus().Pending {
		t.Fatal("expired command was delivered", w.Code, w.Body.String())
	}
	authority.revoked.Store(true)
	if _, err := h.QueuePhoneSettings("phone", newID, edit); err == nil || h.PhoneStatus() != nil {
		t.Fatal("revoked current phone retained desktop settings access")
	}
	h.Check()
	waitSession(t, current)
}

func TestPhoneSettingsRetryAckAndSuccessorIsolation(t *testing.T) {
	h, now, authority := phoneControlHost(t, nil)
	token, current := phoneControlClaim(t, h, "phone", true)
	snapshot := settingsSnapshot()
	microphoneCall(h, "phone", "/status", token, settingsBody(snapshot))
	id, err := h.QueuePhoneSettings("phone", 1, settingsEdit(snapshot))
	if err != nil {
		t.Fatal(err)
	}
	for i := 0; i < 2; i++ {
		*now = now.Add(time.Second)
		w := microphoneCall(h, "phone", "/status", token, settingsBody(snapshot))
		var reply struct {
			Command *phonecontrol.Update `json:"phone_control_command"`
		}
		if w.Code != 200 || json.Unmarshal(w.Body.Bytes(), &reply) != nil || reply.Command == nil || reply.Command.ID != id || string(reply.Command.Changes["audio.fast_recovery"]) != "false" {
			t.Fatal("lost-response retry did not reuse command", w.Code, w.Body.String())
		}
	}
	view := h.PhoneStatus()
	if view == nil || !view.Pending || view.Client != "phone" || !view.UpdatedAt.Equal(*now) {
		t.Fatal("desktop view missing pending/current status", view)
	}
	view.Control.Fields[0].Value[0] = 'x'
	if string(h.PhoneStatus().Control.Fields[0].Value) != "true" {
		t.Fatal("desktop mutated live control state")
	}
	snapshot.Fields[0].Value = json.RawMessage("false")
	snapshot.Revision = strings.Repeat("b", 64)
	snapshot.Ack = &phonecontrol.Ack{ID: id, Status: "applied", Message: "Saved for the next connection."}
	w := microphoneCall(h, "phone", "/status", token, settingsBody(snapshot))
	if w.Code != 200 || strings.Contains(w.Body.String(), "phone_control_command") || h.PhoneStatus().Pending || h.PhoneStatus().Message != snapshot.Ack.Message {
		t.Fatal("acknowledgment did not finish request", w.Code, w.Body.String())
	}
	if _, err := h.QueuePhoneSettings("phone", 1, settingsEdit(snapshot)); err != nil {
		t.Fatal(err)
	}
	microphoneCall(h, "phone", "/stop", token, `{"reason":"user_pause"}`)
	waitSession(t, current)
	if h.PhoneStatus() != nil {
		t.Fatal("paused session still remotely editable")
	}
	if _, err := h.QueuePhoneSettings("phone", 1, settingsEdit(snapshot)); err == nil {
		t.Fatal("paused/offline command was queued")
	}
	token, _ = phoneControlClaim(t, h, "other", true)
	w = microphoneCall(h, "other", "/status", token, settingsBody(settingsSnapshot()))
	if w.Code != 200 || strings.Contains(w.Body.String(), "phone_control_command") || h.PhoneStatus().Pending {
		t.Fatal("old device command reached successor", w.Code, w.Body.String())
	}
	authority.revoked.Store(true)
	if _, err := h.QueuePhoneSettings("phone", 1, settingsEdit(snapshot)); err == nil {
		t.Fatal("revoked identity could queue an update")
	}
}

func TestPhoneTelemetryWorksWithoutLogAndSettingsStayOutOfLogs(t *testing.T) {
	for _, logging := range []bool{false, true} {
		t.Run(map[bool]string{false: "disabled", true: "enabled"}[logging], func(t *testing.T) {
			path := filepath.Join(t.TempDir(), "connection.jsonl")
			var logger *diagnostics.Log
			if logging {
				var err error
				logger, _, err = diagnostics.Create(path, diagnostics.DesktopCapture, time.Now())
				if err != nil {
					t.Fatal(err)
				}
			}
			h, now, _ := phoneControlHost(t, logger)
			token, current := phoneControlClaim(t, h, "phone", true)
			var body map[string]any
			if err := json.Unmarshal([]byte(androidReport), &body); err != nil {
				t.Fatal(err)
			}
			body["version"], body["phone_control"] = 3, settingsSnapshot()
			data, _ := json.Marshal(body)
			w := microphoneCall(h, "phone", "/status", token, string(data))
			expected := `"report_log":"not_recorded"`
			if logging {
				expected = `"report_log":"accepted"`
			}
			if w.Code != 200 || !strings.Contains(w.Body.String(), expected) {
				t.Fatal("telemetry/file logging conflated", w.Code, w.Body.String())
			}
			view := h.PhoneStatus()
			if view == nil || view.Report == nil || view.Report.Metrics["rtt_ms"] == nil || *view.Report.Metrics["rtt_ms"] != 8 || !view.ReportAt.Equal(*now) {
				t.Fatal("phone telemetry missing", view)
			}
			*view.Report.Metrics["rtt_ms"] = 999
			if *h.PhoneStatus().Report.Metrics["rtt_ms"] != 8 {
				t.Fatal("desktop report aliases server memory")
			}
			microphoneCall(h, "phone", "/stop", token, `{}`)
			waitSession(t, current)
			contents, err := os.ReadFile(path)
			if logging {
				if err != nil || !strings.Contains(string(contents), `"rtt_ms":8`) || strings.Contains(string(contents), "audio.fast_recovery") || strings.Contains(string(contents), "Private phone setting") {
					t.Fatal("settings leaked into log or telemetry missing", err)
				}
			} else if !os.IsNotExist(err) {
				t.Fatal("logging disabled still created a file", err)
			}
		})
	}
}

func TestPhoneControlBoundsAreCheckedBeforeMediaAllocation(t *testing.T) {
	for _, values := range [][]string{{"2"}, {""}, {"1", "1"}} {
		h, err := NewPairedHost(microphoneAuthority{}, func(time.Time, OfferOptions) (Resources, error) {
			t.Fatal("invalid capability reached media allocation")
			return Resources{}, nil
		})
		if err != nil {
			t.Fatal(err)
		}
		r := httptest.NewRequest("POST", "https://paired.test/offer", strings.NewReader(`{"version":3}`))
		r.Header.Set("X-Test-Verified-Identity", "phone")
		for _, value := range values {
			r.Header.Add(phonecontrol.Header, value)
		}
		w := httptest.NewRecorder()
		h.ServeHTTP(w, r)
		if w.Code != 400 {
			t.Fatal(w.Code, w.Body.String())
		}
		h.Close("test")
	}
	h, _, _ := phoneControlHost(t, nil)
	token, _ := phoneControlClaim(t, h, "phone", true)
	for _, body := range []string{
		`{"version":3,"phone_control":{"version":1,"unknown":true}}`,
		strings.Repeat(" ", phonecontrol.MaxBody+diagnostics.MaxReportBody) + settingsBody(settingsSnapshot()),
	} {
		if w := microphoneCall(h, "phone", "/status", token, body); w.Code != 400 {
			t.Fatal("malformed/unbounded snapshot accepted", w.Code, w.Body.String())
		}
	}
	if h.PhoneStatus().Control != nil {
		t.Fatal("invalid snapshot changed state")
	}
}
