package windowsaudio

import (
	"context"
	"errors"
	"strings"
	"testing"
	"time"
)

func TestCaptureValidatesBeforeOpeningDevice(t *testing.T) {
	for _, config := range []Config{
		{}, {Duration: time.Minute + time.Millisecond}, {Duration: 100*time.Millisecond + time.Microsecond},
		{Duration: time.Second, EndpointID: "output\x00suffix"}, {Duration: time.Second, EndpointID: string([]byte{0xff})},
		{Duration: time.Second, EndpointID: strings.Repeat("a", 1024)},
	} {
		if _, _, err := Capture(context.Background(), config); err == nil || errors.Is(err, ErrUnsupported) {
			t.Fatalf("missing argument error for %+v: %v", config, err)
		}
	}
	ctx, cancel := context.WithCancel(context.Background())
	cancel()
	if _, _, err := Capture(ctx, Config{Duration: time.Second}); !errors.Is(err, context.Canceled) {
		t.Fatalf("pre-canceled capture: %v", err)
	}
	if !Available() {
		if _, _, err := Capture(context.Background(), Config{Duration: time.Second}); !errors.Is(err, ErrUnsupported) {
			t.Fatalf("platform error: %v", err)
		}
		if _, err := Devices(); !errors.Is(err, ErrUnsupported) {
			t.Fatalf("enumeration platform error: %v", err)
		}
	}
}
