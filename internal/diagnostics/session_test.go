package diagnostics

import (
	"encoding/json"
	"strings"
	"testing"
	"time"

	"github.com/maskarauder/MicDrop/internal/rtc"
)

func terminalFixture() *ReceiverEnd {
	return &ReceiverEnd{Version: 1, CapturedAt: time.Now().UTC(), UptimeMS: 10000,
		Code: "media_recovery_timeout", Stage: "microphone", FailureUptimeMS: pointer(int64(9990)),
		Connection: &Connection{Peer: "disconnected", ICE: "disconnected", Host: "disconnected",
			Runtime: &Runtime{DefaultNetwork: "wifi", DeviceIdle: pointer(false), MicrophonePermission: pointer(true),
				WakeLockHeld: pointer(true), NetworkValidated: pointer(false)}},
		Events: []ConnectionEvent{{UptimeMS: 9000, Kind: "ice", Value: "disconnected"},
			{UptimeMS: 9500, Kind: "peer", Value: "disconnected"}}}
}

func TestTerminalLabelsTimesAndFailureReasonMustAgree(t *testing.T) {
	if !terminalFixture().Valid("connection_failed") {
		t.Fatal("valid terminal rejected")
	}
	for _, code := range strings.Split(failureCodes, "|") {
		if code == "none" {
			continue
		}
		e := terminalFixture()
		e.Code = code
		if !e.Valid("connection_failed") {
			t.Fatalf("known code rejected: %s", code)
		}
	}
	for _, mutate := range []func(*ReceiverEnd){
		func(e *ReceiverEnd) { e.Version = 2 },
		func(e *ReceiverEnd) { e.Code = "exception contains private invitation" },
		func(e *ReceiverEnd) { e.Stage = "https://private-host" },
		func(e *ReceiverEnd) { e.Code = "none" },
		func(e *ReceiverEnd) { e.Connection = nil },
		func(e *ReceiverEnd) { e.Connection.Peer = "peer-address" },
		func(e *ReceiverEnd) { e.Connection.ICE = "candidate-id" },
		func(e *ReceiverEnd) { e.Connection.Runtime.DefaultNetwork = "SSID" },
		func(e *ReceiverEnd) { e.Connection.Runtime.ForegroundService = "private service name" },
		func(e *ReceiverEnd) { e.HTTPStatus = pointer(999) },
		func(e *ReceiverEnd) { e.Connection.Runtime.NetworkChanges = -1 },
		func(e *ReceiverEnd) { e.Connection.Runtime.NetworkChanges = 1 << 53 },
		func(e *ReceiverEnd) { e.FailureUptimeMS = nil },
		func(e *ReceiverEnd) { e.FailureUptimeMS = pointer(int64(10001)) },
		func(e *ReceiverEnd) { e.FailureUptimeMS = pointer(int64(-1)) },
		func(e *ReceiverEnd) { e.Events[0].UptimeMS = 10001 },
		func(e *ReceiverEnd) { e.Events[1].UptimeMS = 8999 },
		func(e *ReceiverEnd) { e.Events[0].Kind = "SDP" },
		func(e *ReceiverEnd) { e.Events[0].Value = "raw exception" },
		func(e *ReceiverEnd) { e.Events = make([]ConnectionEvent, 25) },
		func(e *ReceiverEnd) { e.OmittedEvents = -1 },
	} {
		e := terminalFixture()
		mutate(e)
		if e.Valid("connection_failed") {
			t.Fatalf("unsafe/inconsistent terminal accepted: %+v", e)
		}
	}
	for _, reason := range []string{"user_stop", "user_pause", "focus_loss", "output_lost", "service_stopped"} {
		e := terminalFixture()
		if e.Valid(reason) {
			t.Fatal("failure attached to normal stop")
		}
		e.Code = "none"
		e.FailureUptimeMS = nil
		if !e.Valid(reason) {
			t.Fatalf("normal stop rejected: %s", reason)
		}
	}
	if !(&Connection{Peer: "connected", ICE: "completed", Host: "connected"}).Valid() {
		t.Fatal("unavailable platform observations must remain valid")
	}
}

func TestTerminalSurvivesPeriodicQueuePressureAndLogLimit(t *testing.T) {
	writer := &memoryLog{}
	l := newLog(writer, 48*1024, time.Now())
	for i := 0; i < 2000; i++ {
		l.Playback(rtc.Status{State: "connected"}, reportFixture())
	}
	if l.ReceiverEnd(&rtc.Status{State: "disconnected"}, terminalFixture()) != "accepted" {
		t.Fatal("terminal lost to busy queue")
	}
	if err := l.Close("receiver_failure"); err != nil {
		t.Fatal(err)
	}
	entries := readRecords(t, writer.Bytes())
	if writer.Len() > 48*1024 || len(entries) < 2 || entries[len(entries)-2].Type != "receiver_end" {
		t.Fatal("missing/unbounded terminal")
	}
	var details map[string]any
	data, _ := json.Marshal(entries[len(entries)-1].Details)
	_ = json.Unmarshal(data, &details)
	if details["receiver_diagnostics_written"] != true || details["size_limit_reached"] != true {
		t.Fatal("limit/finalization evidence missing")
	}
	if !strings.Contains(writer.String(), `"code":"media_recovery_timeout"`) ||
		strings.Count(writer.String(), `"type":"receiver_end"`) != 1 {
		t.Fatal("terminal not retained once")
	}
	if l.ReceiverEnd(nil, terminalFixture()) != "closed" {
		t.Fatal("closed log changed")
	}
}
