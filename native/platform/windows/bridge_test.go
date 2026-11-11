package windowsaudio

import (
	"context"
	"errors"
	"strings"
	"testing"
	"time"
)

func TestBridgeRejectsImplicitAndInvalidDestinationBeforeOpeningDevice(t *testing.T) {
	for _, config := range []BridgeConfig{
		{}, {RenderEndpointID: "  ", Duration: time.Second},
		{RenderEndpointID: "id", Duration: 99 * time.Millisecond},
		{RenderEndpointID: "id", Duration: time.Minute + time.Millisecond},
		{RenderEndpointID: "id", Duration: time.Second + time.Microsecond},
		{RenderEndpointID: "id\x00suffix", Duration: time.Second},
		{RenderEndpointID: string([]byte{0xff}), Duration: time.Second},
		{RenderEndpointID: strings.Repeat("a", 1024), Duration: time.Second},
	} {
		if _, err := BridgeCheck(context.Background(), config); err == nil || errors.Is(err, ErrUnsupported) {
			t.Fatalf("invalid destination reached native device open: %+v: %v", config, err)
		}
	}
	ctx, cancel := context.WithCancel(context.Background())
	cancel()
	config := BridgeConfig{RenderEndpointID: "explicit-id", Duration: time.Second}
	if _, err := BridgeCheck(ctx, config); !errors.Is(err, context.Canceled) {
		t.Fatalf("pre-canceled bridge opened audio: %v", err)
	}
	if !Available() {
		if _, err := BridgeCheck(context.Background(), config); !errors.Is(err, ErrUnsupported) {
			t.Fatalf("bridge platform error: %v", err)
		}
		if _, err := InputDevices(); !errors.Is(err, ErrUnsupported) {
			t.Fatalf("input enumeration platform error: %v", err)
		}
	}
}
