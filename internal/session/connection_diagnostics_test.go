package session

import (
	"encoding/json"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"

	"github.com/maskarauder/MicDrop/internal/diagnostics"
	"github.com/maskarauder/MicDrop/internal/rtc"
)

const terminalReport = `{"version":1,"captured_at":"2026-10-01T02:18:39Z","uptime_ms":10000,"code":"media_recovery_timeout","stage":"microphone","failure_uptime_ms":9990,"connection":{"peer":"disconnected","ice":"disconnected","host":"disconnected","runtime":{"screen_on":false,"device_idle":false,"microphone_permission":true,"wake_lock_held":true,"default_network":"wifi","network_validated":false,"network_changes":2}},"events":[{"uptime_ms":9000,"kind":"ice","value":"disconnected"}],"omitted_events":0}`

func diagnosticsSession(t *testing.T) (*Server, *diagnostics.Log, string, string) {
	t.Helper()
	now := time.Now()
	path := filepath.Join(t.TempDir(), "combined.jsonl")
	l, _, err := diagnostics.Create(path, diagnostics.DesktopCapture, now)
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { _ = l.Close("test") })
	invitation := strings.Repeat("a", 43)
	s := New(&fakePeer{status: rtc.Status{State: "disconnected", BytesSent: 1234}}, invitation, now, WithDiagnostics(l))
	w := call(s, "/offer", invitation, `{"version":1}`)
	var offer struct {
		Session               string `json:"session"`
		ConnectionDiagnostics int    `json:"connection_diagnostics_version"`
		GatheringDiagnostics  int    `json:"ice_gathering_diagnostics_version"`
	}
	if w.Code != 200 || json.Unmarshal(w.Body.Bytes(), &offer) != nil || offer.ConnectionDiagnostics != 1 || offer.GatheringDiagnostics != 2 {
		t.Fatal("extension not advertised with logging")
	}
	if call(s, "/answer", offer.Session, `{"version":1,"sdp":"answer"}`).Code != 200 {
		t.Fatal("answer")
	}
	return s, l, path, offer.Session
}

func TestInitialGatheringEvidenceReachesCombinedLogBeforeAnAnswer(t *testing.T) {
	now := time.Now()
	path := filepath.Join(t.TempDir(), "combined.jsonl")
	l, _, err := diagnostics.Create(path, diagnostics.DesktopCapture, now)
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { _ = l.Close("test") })
	invitation := strings.Repeat("a", 43)
	s := New(&fakePeer{status: rtc.Status{State: "new"}}, invitation, now, WithDiagnostics(l))
	w := call(s, "/offer", invitation, `{"version":1}`)
	var offer struct {
		Session   string `json:"session"`
		Gathering int    `json:"ice_gathering_diagnostics_version"`
	}
	if w.Code != 200 || json.Unmarshal(w.Body.Bytes(), &offer) != nil || offer.Gathering != 2 {
		t.Fatal("offer")
	}
	gathering := `"ice_gathering":{"version":1,"result":"timed_out","elapsed_ms":15001,"relay_only":true,"relay_candidates":0,"media_sections":1,"ready_sections":0,"candidate_errors":1,"last_error_code":701},`
	report := strings.Replace(terminalReport, `"connection":`, gathering+`"connection":`, 1)
	report = strings.ReplaceAll(report, "media_recovery_timeout", "stage_timeout")
	report = strings.ReplaceAll(report, `"stage":"microphone"`, `"stage":"routes"`)
	// Strict JSON decoding still rejects identifiers or raw native errors.
	bad := strings.Replace(report, `"candidate_errors":1`, `"url":"turn:private","candidate_errors":1`, 1)
	if call(s, "/stop", offer.Session, `{"reason":"connection_failed","diagnostics":`+bad+`}`).Code != 400 || s.EndReason() != "" {
		t.Fatal("private gathering accepted")
	}
	w = call(s, "/stop", offer.Session, `{"reason":"connection_failed","diagnostics":`+report+`}`)
	if w.Code != 200 || !strings.Contains(w.Body.String(), `"receiver_diagnostics":"accepted"`) {
		t.Fatal("initial gathering not accepted", w.Body.String())
	}
	if err := l.Close(s.EndReason()); err != nil {
		t.Fatal(err)
	}
	data, err := os.ReadFile(path)
	if err != nil || !strings.Contains(string(data), `"last_error_code":701`) || !strings.Contains(string(data), `"stage":"routes"`) {
		t.Fatal("missing gathering evidence", err)
	}
}

func TestReceiverTerminalPairsWindowsAndFinalAndroidEvidence(t *testing.T) {
	s, l, path, token := diagnosticsSession(t)
	body := `{"reason":"connection_failed","diagnostics":` + terminalReport + `}`
	if call(s, "/stop", strings.Repeat("b", 43), body).Code != 401 || s.EndReason() != "" {
		t.Fatal("unauthenticated diagnostics stopped session")
	}
	w := call(s, "/stop", token, body)
	if w.Code != 200 || !strings.Contains(w.Body.String(), `"receiver_diagnostics":"accepted"`) || s.EndReason() != "receiver_failure" {
		t.Fatalf("terminal stop failed: %d %s", w.Code, w.Body.String())
	}
	if err := l.Close(s.EndReason()); err != nil {
		t.Fatal(err)
	}
	data, err := os.ReadFile(path)
	if err != nil {
		t.Fatal(err)
	}
	if !strings.Contains(string(data), `"type":"receiver_end"`) ||
		!strings.Contains(string(data), `"code":"media_recovery_timeout"`) ||
		!strings.Contains(string(data), `"bytes_sent":1234`) ||
		!strings.Contains(string(data), `"receiver_diagnostics_written":true`) ||
		strings.Index(string(data), `"type":"receiver_end"`) > strings.Index(string(data), `"type":"session_end"`) {
		t.Fatalf("missing final combined evidence: %s", data)
	}
}

func TestBadReceiverEvidenceDoesNotStopOrRenewSession(t *testing.T) {
	s, _, _, token := diagnosticsSession(t)
	seen := s.lastSeen
	for _, report := range []string{
		strings.Replace(terminalReport, `"version":1`, `"version":2`, 1),
		strings.Replace(terminalReport, `"code":"media_recovery_timeout"`, `"code":"private error text"`, 1),
		strings.Replace(terminalReport, `"uptime_ms":10000`, `"uptime_ms":1`, 1),
		strings.Replace(terminalReport, `"stage":"microphone"`, `"stage":"https://host"`, 1),
		strings.Replace(terminalReport, `"connection":`, `"invitation":"secret","connection":`, 1),
		strings.Replace(terminalReport, `"runtime":{`, `"runtime":{"SSID":"secret",`, 1),
		strings.Replace(terminalReport, `"network_changes":2`, `"network_changes":-1`, 1),
		strings.Replace(terminalReport, `"kind":"ice"`, `"kind":"candidate"`, 1),
		strings.Repeat(" ", diagnostics.MaxTerminalBody) + terminalReport,
		terminalReport + ` {}`,
	} {
		if call(s, "/stop", token, `{"reason":"connection_failed","diagnostics":`+report+`}`).Code != 400 ||
			s.EndReason() != "" || s.lastSeen != seen {
			t.Fatal("invalid terminal changed session")
		}
	}
	if call(s, "/stop", token, `{"reason":"user_stop","diagnostics":`+terminalReport+`}`).Code != 400 {
		t.Fatal("normal stop accepted failure")
	}
	if call(s, "/stop", token, `{"reason":"user_stop"}`).Code != 200 {
		t.Fatal("old client stop rejected by new host")
	}
}

func TestConnectionReportsAreNegotiatedAndKeepLegacyClients(t *testing.T) {
	s, _, _, token := diagnosticsSession(t)
	if postReport(s, token, androidReport).Code != 200 {
		t.Fatal("legacy report rejected")
	}
	extension := `"connection":{"peer":"connected","ice":"completed","host":"connected","runtime":{"default_network":"wifi","network_changes":0,"network_validated":false}},`
	body := strings.Replace(strings.Replace(androidReport, `"sequence":1`, `"sequence":2`, 1), `"metrics":`, extension+`"metrics":`, 1)
	if postReport(s, token, body).Code != 200 {
		t.Fatal("LAN without internet validation rejected")
	}
	if postReport(s, token, strings.Replace(body, `"peer":"connected"`, `"peer":"secret-peer-id"`, 1)).Code != 400 {
		t.Fatal("private label reached log")
	}
	old, _, _, oldToken := connected(t)
	if postReport(old, oldToken, strings.Replace(body, `"sequence":2`, `"sequence":1`, 1)).Code != 400 {
		t.Fatal("unadvertised report extension accepted")
	}
	gathering := `"ice_gathering":{"version":1,"result":"complete","relay_only":true,"relay_candidates":1,"media_sections":1,"ready_sections":1},`
	withGathering := strings.Replace(androidReport, `"metrics":`, gathering+`"metrics":`, 1)
	if postReport(old, oldToken, withGathering).Code != 400 {
		t.Fatal("unadvertised gathering accepted")
	}
	if postReport(s, token, strings.Replace(withGathering, `"sequence":1`, `"sequence":3`, 1)).Code != 200 {
		t.Fatal("negotiated gathering rejected")
	}
	if call(old, "/stop", oldToken, `{"reason":"connection_failed","diagnostics":`+terminalReport+`}`).Code != 400 {
		t.Fatal("unadvertised terminal accepted")
	}
	if call(old, "/stop", oldToken, `{"reason":"user_stop"}`).Code != 200 {
		t.Fatal("legacy stop broken")
	}
}
