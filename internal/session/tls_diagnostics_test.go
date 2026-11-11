package session

import (
	"os"
	"strings"
	"testing"
)

func TestTLSTrustReportRequiresNegotiationAndRejectsPrivateData(t *testing.T) {
	s, log, path, token := diagnosticsSession(t)
	extension := `"tls_certificate_verification":{"version":1,"checks":1,"failures":0,"last_result":"trusted"},`
	body := strings.Replace(androidReport, `"metrics":`, extension+`"metrics":`, 1)
	seen := s.lastSeen
	for _, bad := range []string{
		strings.Replace(body, `"checks":1`, `"checks":1000001`, 1),
		strings.Replace(body, `"checks":1`, `"checks":0`, 1),
		strings.Replace(body, `"failures":0`, `"failures":2`, 1),
		strings.Replace(body, `"failures":0`, `"failures":-1`, 1),
		strings.Replace(body, `"last_result":"trusted"`, `"last_result":"rejected"`, 1),
		strings.Replace(body, `"last_result":"trusted"`, `"last_result":"private certificate error"`, 1),
		strings.Replace(body, `"checks":1`, `"checks":1,"server":"turns:private"`, 1),
	} {
		if postReport(s, token, bad).Code != 400 || s.lastSeen != seen || s.lastReport != 0 {
			t.Fatal("Invalid TLS diagnostics reached the log or renewed the session")
		}
	}
	old, _, _, oldToken := connected(t)
	if postReport(old, oldToken, body).Code != 400 {
		t.Fatal("Unadvertised TLS diagnostics accepted")
	}
	if w := postReport(s, token, body); w.Code != 200 {
		t.Fatal("TLS counters rejected", w.Body.String())
	}
	if err := log.Close("test"); err != nil {
		t.Fatal(err)
	}
	data, err := os.ReadFile(path)
	if err != nil || !strings.Contains(string(data), `"tls_certificate_verification"`) || strings.Contains(string(data), "private") {
		t.Fatal("TLS evidence missing or private data logged", err)
	}
}
