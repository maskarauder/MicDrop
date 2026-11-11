package main

import (
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"io"
	"strings"
	"testing"
	"time"

	windowsaudio "github.com/maskarauder/MicDrop/native/platform/windows"
)

func TestBridgeCLIRequiresExplicitValidatedDestination(t *testing.T) {
	for _, args := range [][]string{
		nil, {"--render-device", ""}, {"--render-device", "id", "--duration", "0s"},
		{"--render-device", "id", "--duration", "61s"}, {"--render-device", "id", "--duration", "100.1ms"},
		{"--render-device", "id\x00suffix"}, {"--render-device", "id", "extra"}, {"--device", "id"},
	} {
		called := false
		code := runBridgeCheck(context.Background(), args, io.Discard, io.Discard,
			func(context.Context, windowsaudio.BridgeConfig) (windowsaudio.BridgeReport, error) {
				called = true
				return windowsaudio.BridgeReport{}, nil
			})
		if code != 2 || called {
			t.Fatalf("invalid configuration opened a device: %v, code=%d called=%v", args, code, called)
		}
	}
	if code := runBridgeDevices([]string{"extra"}, io.Discard, io.Discard); code != 2 {
		t.Fatalf("accepted extra enumeration arguments: %d", code)
	}
}

func TestBridgeCLIKeepsProgressOutOfReportAndPreservesDestination(t *testing.T) {
	var stdout, stderr bytes.Buffer
	code := runBridgeCheck(context.Background(), []string{"--render-device", "chosen-cable", "--duration", "5s"}, &stdout, &stderr,
		func(_ context.Context, config windowsaudio.BridgeConfig) (windowsaudio.BridgeReport, error) {
			if config.RenderEndpointID != "chosen-cable" || config.Duration != 5*time.Second {
				t.Fatalf("explicit choice changed: %+v", config)
			}
			return windowsaudio.BridgeReport{Device: windowsaudio.Device{ID: config.RenderEndpointID}, Frames: 240000, RequestedMS: 5000}, nil
		})
	var report struct {
		windowsaudio.BridgeReport
		Limits string `json:"measurement_limits"`
	}
	if code != 0 || json.Unmarshal(stdout.Bytes(), &report) != nil || report.Device.ID != "chosen-cable" || report.Limits == "" || !strings.Contains(stderr.String(), "Ctrl+C") {
		t.Fatalf("lost report/destination/progress: code=%d stdout=%s stderr=%s", code, &stdout, &stderr)
	}
}

func TestBridgeCLICancellationAndFailureDoNotProduceSuccessReport(t *testing.T) {
	for _, test := range []struct {
		err  error
		code int
	}{{context.Canceled, 130}, {errors.New("endpoint invalidated"), 1}} {
		var stdout, stderr bytes.Buffer
		code := runBridgeCheck(context.Background(), []string{"--render-device", "chosen-cable"}, &stdout, &stderr,
			func(context.Context, windowsaudio.BridgeConfig) (windowsaudio.BridgeReport, error) {
				return windowsaudio.BridgeReport{}, test.err
			})
		if code != test.code || stdout.Len() != 0 || stderr.Len() == 0 {
			t.Fatalf("reported success after cancellation/failure: %d %s %s", code, &stdout, &stderr)
		}
	}
}
