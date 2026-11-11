package main

import (
	"net/http/httptest"
	"strings"
	"testing"
	"time"

	"github.com/maskarauder/MicDrop/internal/desktop"
	"github.com/maskarauder/MicDrop/internal/diagnostics"
	"github.com/maskarauder/MicDrop/internal/phonecontrol"
	"github.com/maskarauder/MicDrop/internal/rtc"
	"github.com/maskarauder/MicDrop/internal/session"
)

func TestDesktopMetricsUsePhoneObservationsNotConfiguredBufferLatency(t *testing.T) {
	rtt, buffer, queue := 15.0, 60.0, 300.0
	now := time.Now()
	phone := &session.PhoneStatus{Client: "phone", UpdatedAt: now, ReportAt: now.Add(-time.Second), Report: &diagnostics.AndroidReport{
		Metrics: map[string]*float64{"rtt_ms": &rtt, "buffer_ms": &buffer}, Output: &diagnostics.Output{EstimatedQueueMS: &queue},
		Microphone: &diagnostics.Microphone{State: "muted"},
	}}
	view := desktopPhoneState(phone, &rtc.Status{Direction: "duplex", BridgeBufferFrames: 1056, BridgeMixRate: 48000})
	if view.Mode != "Duplex · microphone muted" || *view.Metrics.RTTMS != 15 || *view.Metrics.PlaybackBufferMS != 60 || *view.Metrics.OutputQueueMS != 300 || view.Metrics.JitterMS != nil || !view.MetricsAt.Equal(phone.ReportAt) {
		t.Fatal(view)
	}
	phone.Report = nil
	view = desktopPhoneState(phone, &rtc.Status{Direction: "phone_microphone", BridgeBufferFrames: 1056, BridgeMixRate: 48000})
	if view.Mode != "Phone microphone" || view.Metrics.RTTMS != nil || view.Metrics.PlaybackBufferMS != nil || view.Metrics.OutputQueueMS != nil {
		t.Fatal("missing telemetry must stay unavailable", view)
	}
}

func TestDesktopRowCarriesTheOffersSettingsCapability(t *testing.T) {
	key := strings.Repeat("b", 64)
	manager := resetTestManager(t, &resetTestStore{data: resetTestState(strings.Repeat("a", 64), key)})
	for _, negotiated := range []bool{false, true} {
		host, err := session.NewPairedHost(resetTestAuthority{manager}, func(time.Time, session.OfferOptions) (session.Resources, error) {
			return session.Resources{ID: 7, Peer: &resetTestPeer{}}, nil
		})
		if err != nil {
			t.Fatal(err)
		}
		r := httptest.NewRequest("POST", "https://192.168.1.2/offer", strings.NewReader(`{"version":3}`))
		r.Header.Set("X-Test-Key", key)
		if negotiated {
			r.Header.Set(phonecontrol.Header, "1")
		}
		w := httptest.NewRecorder()
		host.ServeHTTP(w, r)
		phone := host.PhoneStatus()
		host.Close("test_complete")
		if w.Code != 200 || phone == nil {
			t.Fatal(negotiated, w.Code, w.Body.String())
		}
		// Before any snapshot, only the flag tells an older phone apart.
		if row := desktopPhoneState(phone, nil); row.Key != key || row.Settings != nil || row.SettingsSupported != negotiated {
			t.Fatal(negotiated, row)
		}
	}
	snapshot := &phonecontrol.Snapshot{Version: phonecontrol.Version, Revision: strings.Repeat("a", 64)}
	row := desktopPhoneState(&session.PhoneStatus{Client: "phone", Control: snapshot, ControlNegotiated: true, Pending: true, Message: "Setting applied on the phone."}, nil)
	if row.Settings != snapshot || !row.SettingsSupported || !row.SettingsPending || row.SettingsMessage != "Setting applied on the phone." {
		t.Fatal(row)
	}
}

func TestSessionBeginForwardsOnlyTheHostsResumeLabel(t *testing.T) {
	key := strings.Repeat("b", 64)
	manager := resetTestManager(t, &resetTestStore{data: resetTestState(strings.Repeat("a", 64), key)})
	for _, tc := range []struct{ resume, reason, want string }{
		{"", "", ""}, {"1", "", ""}, {"1", "manual", "manual"}, {"1", "automatic", "automatic"},
		{"1", "focus_regain", "focus_regain"}, {"1", "accessory", ""},
	} {
		var begun desktop.Event
		host, err := session.NewPairedHost(resetTestAuthority{manager}, func(_ time.Time, offer session.OfferOptions) (session.Resources, error) {
			begun = desktopSessionBegin(7, offer)
			return session.Resources{Peer: &resetTestPeer{}}, nil
		})
		if err != nil {
			t.Fatal(err)
		}
		r := httptest.NewRequest("POST", "https://192.168.1.2/offer", strings.NewReader(`{"version":3}`))
		r.Header.Set("X-Test-Key", key)
		if tc.resume != "" {
			r.Header.Set("X-MicDrop-Session-Resume", tc.resume)
		}
		if tc.reason != "" {
			r.Header.Set("X-MicDrop-Session-Resume-Reason", tc.reason)
		}
		w := httptest.NewRecorder()
		host.ServeHTTP(w, r)
		host.Close("test_complete")
		if w.Code != 200 || begun.Kind != "session_begin" || begun.Session != 7 || begun.PhoneKey != key ||
			begun.Resuming != (tc.resume == "1") || begun.ResumeReason != tc.want {
			t.Fatal(tc, w.Code, w.Body.String(), begun)
		}
	}
}
