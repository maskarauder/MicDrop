package main

import (
	"context"
	"errors"
	"flag"
	"fmt"
	"io"
	"time"

	windowsaudio "github.com/maskarauder/MicDrop/native/platform/windows"
)

type bridgeFunc func(context.Context, windowsaudio.BridgeConfig) (windowsaudio.BridgeReport, error)

func runBridgeDevices(args []string, stdout, stderr io.Writer) int {
	if len(args) != 0 {
		fmt.Fprintln(stderr, "bridge-devices takes no arguments")
		return 2
	}
	render, err := windowsaudio.Devices()
	if err != nil {
		fmt.Fprintln(stderr, err)
		return 1
	}
	inputs, err := windowsaudio.InputDevices()
	if err != nil {
		fmt.Fprintln(stderr, err)
		return 1
	}
	if err := writeJSON(stdout, struct {
		Render []windowsaudio.Device `json:"render_endpoints"`
		Inputs []windowsaudio.Device `json:"recording_endpoints"`
	}{render, inputs}); err != nil {
		fmt.Fprintln(stderr, err)
		return 1
	}
	return 0
}

func runBridgeCheck(ctx context.Context, args []string, stdout, stderr io.Writer, bridge bridgeFunc) int {
	flags := flag.NewFlagSet("bridge-check", flag.ContinueOnError)
	flags.SetOutput(stderr)
	id := flags.String("render-device", "", "explicit cable render endpoint ID from bridge-devices (no default fallback)")
	duration := flags.Duration("duration", 10*time.Second, "test signal duration, 100ms to 1m in whole milliseconds")
	if err := flags.Parse(args); err != nil {
		return 2
	}
	config := windowsaudio.BridgeConfig{RenderEndpointID: *id, Duration: *duration}
	if err := config.Validate(); err != nil {
		fmt.Fprintln(stderr, err)
		return 2
	}
	if flags.NArg() != 0 {
		fmt.Fprintln(stderr, "bridge-check accepts flags only")
		return 2
	}
	fmt.Fprintf(stderr, "Sending a quiet synthetic test signal to the selected endpoint for %s. Press Ctrl+C to stop.\n", *duration)
	report, err := bridge(ctx, config)
	if errors.Is(err, context.Canceled) {
		fmt.Fprintln(stderr, "Bridge check stopped.")
		return 130
	}
	if err != nil {
		fmt.Fprintln(stderr, err)
		return 1
	}
	if err := writeJSON(stdout, struct {
		windowsaudio.BridgeReport
		Signal string `json:"test_signal"`
		Limits string `json:"measurement_limits"`
	}{report, "440 Hz 1s / silence 1s / 880 Hz 1s / silence 1s; peak 0.05; identical stereo channels",
		"Submission and OS buffer figures do not prove virtual-input delivery or physical latency. Confirm the cable's recording endpoint in another application."}); err != nil {
		fmt.Fprintln(stderr, err)
		return 1
	}
	return 0
}
