package session

import (
	"net/http/httptest"
	"os"
	"strings"
	"testing"
	"time"

	"github.com/maskarauder/MicDrop/internal/diagnostics"
	"github.com/maskarauder/MicDrop/internal/rtc"
)

func TestEarlyMicrophoneFailuresKeepTerminalStatusAndListener(t *testing.T) {
	for _, trigger := range []string{"control", "status", "watchdog"} {
		t.Run(trigger, func(t *testing.T) {
			h, p, _ := microphoneHost(t)
			l, path, err := diagnostics.CreateInDirectory(t.TempDir(), diagnostics.PhoneMicrophone, time.Now())
			if err != nil {
				t.Fatal(err)
			}
			terminal := make(chan *rtc.Status, 1)
			h.microphoneFactory = func(time.Time, OfferOptions) (Resources, error) {
				return Resources{Peer: p, Log: l, End: func(_ string, _ error, status *rtc.Status) {
					if p.closes.Load() != 1 {
						t.Error("terminal callback ran before native teardown")
					}
					terminal <- status
				}}, nil
			}
			token, current := microphoneClaim(t, h)
			if microphoneCall(h, "phone", "/answer", token, `{"version":3,"sdp":"answer"}`).Code != 200 {
				t.Fatal("answer")
			}
			p.status.BridgeFailed = true
			p.status.BridgeErrorHRESULT = -2147024809
			p.status.BridgeErrorOperation = "Pull decoded microphone audio"
			switch trigger {
			case "control":
				p.failControl = true
				if microphoneCall(h, "phone", "/microphone", token, `{"version":3,"muted":false}`).Code != 500 {
					t.Fatal("control failure hidden")
				}
			case "status":
				r := httptest.NewRequest("GET", "https://192.168.1.2/status", nil)
				r.Header.Set("X-Test-Verified-Identity", "phone")
				r.Header.Set("Authorization", "Bearer "+token)
				w := httptest.NewRecorder()
				h.ServeHTTP(w, r)
				if w.Code != 410 {
					t.Fatal("status failure hidden")
				}
			case "watchdog":
				h.Check()
			}
			waitSession(t, current)
			if status := <-terminal; status == nil || status.BridgeErrorHRESULT != -2147024809 ||
				status.BridgeErrorOperation != "Pull decoded microphone audio" {
				t.Fatal("native failure details lost before terminal callback")
			}
			data, err := os.ReadFile(path)
			if err != nil {
				t.Fatal(err)
			}
			for _, expected := range []string{`"source":"phone_microphone"`, `"phone_microphone":"requested"`,
				`"playback":"off"`, `"bridge_error_hresult":-2147024809`, `"bridge_error_operation":"Pull decoded microphone audio"`,
				`"reason":"microphone_bridge_failed"`} {
				if !strings.Contains(string(data), expected) {
					t.Fatalf("early failure log lacks %s: %s", expected, data)
				}
			}
			if strings.Index(string(data), `"type":"windows_status"`) > strings.Index(string(data), `"type":"session_end"`) ||
				strings.Contains(string(data), token) || strings.Contains(string(data), "desktop_capture") {
				t.Fatal("terminal snapshot ordering or source/privacy metadata incorrect")
			}
			if microphoneCall(h, "phone", "/offer", "", `{"version":3}`).Code != 200 {
				t.Fatal("bridge failure ended listener")
			}
		})
	}
}
