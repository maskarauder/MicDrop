package main

import (
	"context"
	"io"
	"strings"
	"testing"
)

func TestMicrophoneCLIRejectsImplicitOrLegacyDestination(t *testing.T) {
	for _, args := range [][]string{
		{"--host", "192.168.1.72", "--microphone-device", "chosen-cable"},
		{"--host", "192.168.1.72", "--paired", "--microphone-device", ""},
		{"--host", "192.168.1.72", "--paired", "--microphone-device", "id\x00suffix"},
		{"--host", "192.168.1.72", "--paired", "--microphone-device", strings.Repeat("x", 1024)},
	} {
		if code := runStream(context.Background(), args, io.Discard, io.Discard); code != 2 {
			t.Fatalf("invalid microphone destination reached startup: args=%q code=%d", args, code)
		}
	}
}
