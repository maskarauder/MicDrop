package main

import (
	"fmt"
	"io"

	"github.com/maskarauder/MicDrop/internal/rtc"
)

// Exercise the installed Go-to-MSVC DLL boundary without an audio endpoint,
// remote peer, or authorization to produce PCM. SDP is intentionally discarded.
func runRTCCheck(stdout, stderr io.Writer) int {
	peer, err := rtc.Open("", true)
	if err != nil {
		fmt.Fprintln(stderr, err)
		return 1
	}
	defer peer.Close()
	if _, err = peer.Offer(); err != nil {
		fmt.Fprintln(stderr, err)
		return 1
	}
	status, err := peer.Status()
	if err != nil || status.CaptureFailed || status.PCMFramesSent != 0 {
		fmt.Fprintln(stderr, "WebRTC runtime check failed")
		return 1
	}
	if err = writeJSON(stdout, status); err != nil {
		fmt.Fprintln(stderr, err)
		return 1
	}
	return 0
}
