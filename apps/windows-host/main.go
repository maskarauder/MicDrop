// windows-host runs the desktop app, authenticated audio host, and diagnostics.
package main

import (
	"context"
	"encoding/json"
	"flag"
	"fmt"
	"io"
	"os"
	"os/signal"
	"path/filepath"
	"runtime"
	"strings"
	"time"

	"github.com/maskarauder/MicDrop/internal/version"
	"github.com/maskarauder/MicDrop/native/media"
	windowsaudio "github.com/maskarauder/MicDrop/native/platform/windows"
)

func main() {
	ctx, stop := signal.NotifyContext(context.Background(), os.Interrupt)
	args := os.Args[1:]
	if len(args) == 0 && strings.EqualFold(filepath.Base(os.Args[0]), "MicDrop.exe") {
		args = []string{"desktop"}
	}
	code := runContext(ctx, args, os.Stdout, os.Stderr)
	stop()
	os.Exit(code)
}

func run(args []string, stdout, stderr io.Writer) int {
	return runContext(context.Background(), args, stdout, stderr)
}

func runContext(ctx context.Context, args []string, stdout, stderr io.Writer) int {
	if len(args) == 0 {
		fmt.Fprintln(stderr, "Usage: windows-host version | desktop | doctor | rtc-check | devices | bridge-devices | bridge-check --render-device <id> [--duration 10s] | identity init|status | remote import|status|forget | capture [--device <id>] [--duration 5s] [--output <new.wav>] | tone --output <new.wav> [--duration 1s] | stream --host <LAN IPv4> [--paired [--remote] [--pair] [--revoke-all] [--microphone-device <cable-render-id>]] [--probe] [--log-dir <directory> | --no-log] [--log-retention <count>]")
		return 2
	}
	switch args[0] {
	case "version":
		if len(args) != 1 {
			fmt.Fprintln(stderr, "version takes no arguments")
			return 2
		}
		if err := writeJSON(stdout, version.Build()); err != nil {
			fmt.Fprintln(stderr, err)
			return 1
		}
		return 0
	case "desktop":
		return runDesktop(args[1:], stderr)
	case "remote":
		return runRemote(args[1:], stdout, stderr)
	case "bridge-devices":
		return runBridgeDevices(args[1:], stdout, stderr)
	case "bridge-check":
		return runBridgeCheck(ctx, args[1:], stdout, stderr, windowsaudio.BridgeCheck)
	case "identity":
		return runIdentity(args[1:], stdout, stderr)
	case "rtc-check":
		if len(args) != 1 {
			fmt.Fprintln(stderr, "rtc-check takes no arguments")
			return 2
		}
		return runRTCCheck(stdout, stderr)
	case "stream":
		return runStream(ctx, args[1:], stdout, stderr)
	case "doctor":
		if len(args) != 1 {
			fmt.Fprintln(stderr, "doctor takes no arguments")
			return 2
		}
		err := json.NewEncoder(stdout).Encode(struct {
			Stage     string `json:"stage"`
			Platform  string `json:"platform"`
			NativeABI uint32 `json:"native_abi"`
			Capture   bool   `json:"capture_implemented"`
			Streaming bool   `json:"network_streaming_implemented"`
		}{"m0-webrtc-lan", runtime.GOOS + "/" + runtime.GOARCH, media.ABIVersion(), windowsaudio.Available(), runtime.GOOS == "windows" && runtime.GOARCH == "amd64"})
		if err != nil {
			fmt.Fprintln(stderr, err)
			return 1
		}
		return 0
	case "devices":
		if len(args) != 1 {
			fmt.Fprintln(stderr, "devices takes no arguments")
			return 2
		}
		devices, err := windowsaudio.Devices()
		if err == nil {
			err = writeJSON(stdout, devices)
		}
		if err != nil {
			fmt.Fprintln(stderr, err)
			return 1
		}
		return 0
	case "capture":
		return runCapture(ctx, args[1:], stdout, stderr, windowsaudio.Capture)
	case "tone":
		flags := flag.NewFlagSet("tone", flag.ContinueOnError)
		flags.SetOutput(stderr)
		output := flags.String("output", "", "new WAV file to create (existing files are never overwritten)")
		duration := flags.Duration("duration", time.Second, "duration from 1ms to 1m")
		if err := flags.Parse(args[1:]); err != nil {
			return 2
		}
		if *output == "" || flags.NArg() != 0 || *duration < time.Millisecond || *duration > time.Minute {
			fmt.Fprintln(stderr, "tone requires --output and a duration between 1ms and 1m")
			return 2
		}
		if err := createToneFile(*output, *duration); err != nil {
			fmt.Fprintln(stderr, err)
			return 1
		}
		fmt.Fprintf(stdout, "Created %s: 48 kHz stereo, 440 Hz test tone, amplitude 0.05.\n", *output)
		return 0
	default:
		fmt.Fprintf(stderr, "Unknown command %q; use doctor, rtc-check, devices, bridge-devices, bridge-check, identity, capture, tone, or stream.\n", args[0])
		return 2
	}
}
