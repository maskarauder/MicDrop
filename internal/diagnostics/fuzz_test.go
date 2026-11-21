// SPDX-License-Identifier: MPL-2.0
package diagnostics

import (
	"encoding/json"
	"testing"
)

// Phones post these reports to the host. Validation must reject or accept any
// decodable body without panicking, and an accepted report must stay encodable
// for the diagnostics log. Without -fuzz the seeds run as ordinary tests.

func FuzzAndroidReportValid(f *testing.F) {
	duplex := reportFixture()
	duplex.Direction = "duplex"
	duplex.Microphone = &Microphone{State: "running", Route: "built-in microphone", SampleRate: 48000, Channels: 1,
		RequestedRoute: "built-in microphone", RouteVerified: pointer(true),
		Processing: &MicrophoneProcessing{EchoCancellation: true, NoiseReduction: true}}
	recovering := reportFixture()
	recovering.LANRecovery = &LANRecovery{Phase: "recovering", Restarts: 2, SignalingRoute: "wifi"}
	for _, report := range []*AndroidReport{reportFixture(), duplex, recovering} {
		if !report.Valid() {
			f.Fatal("seed report is not valid")
		}
		seed, err := json.Marshal(report)
		if err != nil {
			f.Fatal(err)
		}
		f.Add(string(seed))
	}
	f.Add(`{}`)
	f.Add(`{"sequence":1,"output":{},"recovery":{},"microphone":{"processing":{}},"lan_recovery":{}}`)
	f.Fuzz(func(t *testing.T, body string) {
		var report AndroidReport
		if json.Unmarshal([]byte(body), &report) != nil || !report.Valid() {
			return
		}
		if _, err := json.Marshal(&report); err != nil {
			t.Fatalf("accepted report cannot be encoded: %v", err)
		}
	})
}

func FuzzReceiverEndValid(f *testing.F) {
	terminal := terminalFixture()
	if !terminal.Valid("connection_failed") {
		f.Fatal("seed terminal is not valid")
	}
	seed, err := json.Marshal(terminal)
	if err != nil {
		f.Fatal(err)
	}
	f.Add(string(seed), "connection_failed")
	f.Add(string(seed), "user_stop")
	f.Add(`{"version":1,"connection":{"runtime":{}},"events":[{}]}`, "")
	f.Fuzz(func(t *testing.T, body, reason string) {
		var end ReceiverEnd
		if json.Unmarshal([]byte(body), &end) != nil || !end.Valid(reason) {
			return
		}
		if !end.Connection.Valid() {
			t.Fatal("accepted terminal carries an invalid connection")
		}
		if _, err := json.Marshal(&end); err != nil {
			t.Fatalf("accepted terminal cannot be encoded: %v", err)
		}
	})
}
