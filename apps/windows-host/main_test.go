package main

import (
	"bytes"
	"encoding/binary"
	"encoding/json"
	"io"
	"os"
	"path/filepath"
	"runtime"
	"testing"
)

func TestToneFileAndNoOverwrite(t *testing.T) {
	path := filepath.Join(t.TempDir(), "tone.wav")
	var output bytes.Buffer
	args := []string{"tone", "--output", path, "--duration", "25ms"}
	if code := run(args, &output, &output); code != 0 {
		t.Fatal(output.String())
	}
	wav, err := os.ReadFile(path)
	if err != nil {
		t.Fatal(err)
	}
	if len(wav) != 44+1200*4 || string(wav[:4]) != "RIFF" || string(wav[8:16]) != "WAVEfmt " ||
		binary.LittleEndian.Uint32(wav[40:44]) != 1200*4 || binary.LittleEndian.Uint16(wav[22:24]) != 2 {
		t.Fatalf("invalid WAV: bytes=%d", len(wav))
	}
	if bytes.Equal(wav[44:], make([]byte, len(wav)-44)) {
		t.Fatal("tone is silent")
	}
	if code := run(args, &output, &output); code == 0 {
		t.Fatal("overwrote existing file")
	}
	after, err := os.ReadFile(path)
	if err != nil || !bytes.Equal(wav, after) {
		t.Fatal("existing WAV was changed")
	}
}

func TestDoctorAndInvalidArguments(t *testing.T) {
	var output bytes.Buffer
	if run([]string{"doctor"}, &output, &output) != 0 {
		t.Fatal(output.String())
	}
	var report struct {
		NativeABI uint32 `json:"native_abi"`
		Streaming bool   `json:"network_streaming_implemented"`
	}
	if err := json.Unmarshal(output.Bytes(), &report); err != nil {
		t.Fatal(err)
	}
	if report.NativeABI != 1 || report.Streaming != (runtime.GOOS == "windows" && runtime.GOARCH == "amd64") {
		t.Fatalf("incorrect capabilities: %+v", report)
	}
	for _, args := range [][]string{nil, {"unknown"}, {"doctor", "extra"}, {"tone"}, {"tone", "--output", "unused.wav", "--duration", "-1s"},
		{"stream", "--host", "192.168.1.2", "--log", "unused.jsonl", "--no-log"},
		{"stream", "--host", "192.168.1.2", "--invitation-ttl", "0s"},
		{"stream", "--host", "192.168.1.2", "--invitation-ttl", "24h"},
		{"stream", "--host", "192.168.1.2", "--pair"},
		{"stream", "--host", "192.168.1.2", "--revoke-all"},
		{"stream", "--host", "192.168.1.2", "--no-discovery"},
		{"stream", "--host", "192.168.1.2", "--state-dir", "C:\\test"},
		{"stream", "--host", "192.168.1.2", "--paired", "--invitation-ttl", "12h"},
		{"stream", "--host", "192.168.1.2", "--log-dir", ""}} {
		if run(args, io.Discard, io.Discard) != 2 {
			t.Fatalf("accepted %v", args)
		}
	}
}

type shortWriter struct{}

func (shortWriter) Write(data []byte) (int, error) { return len(data) - 1, nil }

func TestWAVWriteFailure(t *testing.T) {
	if err := writeToneWAV(shortWriter{}, 48); err != io.ErrShortWrite {
		t.Fatalf("lost write error: %v", err)
	}
}

func TestStreamRejectsUnsupportedPlatformBeforeListening(t *testing.T) {
	if runtime.GOOS == "windows" && runtime.GOARCH == "amd64" {
		t.Skip("supported platform")
	}
	if code := run([]string{"stream", "--host", "192.168.1.2"}, io.Discard, io.Discard); code != 1 {
		t.Fatalf("unsupported streaming returned %d", code)
	}
}
