package main

import (
	"bytes"
	"context"
	"encoding/binary"
	"encoding/json"
	"errors"
	"io"
	"os"
	"path/filepath"
	"testing"
	"time"

	windowsaudio "github.com/maskarauder/MicDrop/native/platform/windows"
)

func TestCaptureNoRecordingByDefault(t *testing.T) {
	var output bytes.Buffer
	fn := func(_ context.Context, c windowsaudio.Config) (windowsaudio.Report, []byte, error) {
		if c.Record || c.EndpointID != "chosen-output" || c.Duration != 2*time.Second {
			t.Fatalf("unexpected capture config: %+v", c)
		}
		return windowsaudio.Report{Frames: 10, Levels: []windowsaudio.Level{{Peak: 0.5}}}, nil, nil
	}
	if code := runCapture(context.Background(), []string{"--device", "chosen-output", "--duration", "2s"}, &output, io.Discard, fn); code != 0 {
		t.Fatalf("exit %d", code)
	}
	var report map[string]any
	if err := json.Unmarshal(output.Bytes(), &report); err != nil || report["frames"] != float64(10) || report["wav_file"] != nil {
		t.Fatalf("JSON report: %s; %v", output.String(), err)
	}
}

func TestCaptureRecordingPreservesFormatAndNeverOverwrites(t *testing.T) {
	path := filepath.Join(t.TempDir(), "capture.wav")
	pcm := []byte{0, 1, 0, 2, 0, 3, 0, 4, 0, 5, 0, 6, 0, 7, 0, 8, 0, 9, 0, 10, 0, 11, 0, 12}
	called := 0
	fn := func(_ context.Context, c windowsaudio.Config) (windowsaudio.Report, []byte, error) {
		called++
		if !c.Record {
			t.Fatal("recording intent lost")
		}
		return windowsaudio.Report{Frames: 2, Format: windowsaudio.Format{SampleRate: 44100, Channels: 6, ChannelMask: 0x3f}}, pcm, nil
	}
	args := []string{"--output", path}
	if runCapture(context.Background(), args, io.Discard, io.Discard, fn) != 0 {
		t.Fatal("capture failed")
	}
	wav, err := os.ReadFile(path)
	if err != nil {
		t.Fatal(err)
	}
	if len(wav) != 68+len(pcm) || string(wav[:4]) != "RIFF" || string(wav[60:64]) != "data" ||
		binary.LittleEndian.Uint32(wav[4:]) != uint32(len(wav)-8) ||
		binary.LittleEndian.Uint16(wav[20:]) != 0xfffe || binary.LittleEndian.Uint16(wav[22:]) != 6 ||
		binary.LittleEndian.Uint32(wav[24:]) != 44100 || binary.LittleEndian.Uint32(wav[40:]) != 0x3f ||
		binary.LittleEndian.Uint32(wav[64:]) != uint32(len(pcm)) || !bytes.Equal(wav[68:], pcm) {
		t.Fatalf("bad multichannel WAV: %v", wav)
	}
	if runCapture(context.Background(), args, io.Discard, io.Discard, fn) != 1 || called != 1 {
		t.Fatal("existing file must fail before opening audio device")
	}
	after, err := os.ReadFile(path)
	if err != nil || !bytes.Equal(wav, after) {
		t.Fatal("existing recording changed")
	}
}

func TestCaptureFailureRemovesReservedFile(t *testing.T) {
	for _, reason := range []string{"native error", "canceled", "no packets", "bad PCM"} {
		t.Run(reason, func(t *testing.T) {
			path := filepath.Join(t.TempDir(), "capture.wav")
			fn := func(context.Context, windowsaudio.Config) (windowsaudio.Report, []byte, error) {
				switch reason {
				case "native error":
					return windowsaudio.Report{}, nil, errors.New("device invalidated")
				case "canceled":
					return windowsaudio.Report{}, nil, context.Canceled
				case "bad PCM":
					return windowsaudio.Report{Frames: 1, Format: windowsaudio.Format{SampleRate: 48000, Channels: 2}}, []byte{0}, nil
				default:
					return windowsaudio.Report{}, nil, nil
				}
			}
			if runCapture(context.Background(), []string{"--output", path}, io.Discard, io.Discard, fn) != 1 {
				t.Fatal("failure was hidden")
			}
			if _, err := os.Stat(path); !errors.Is(err, os.ErrNotExist) {
				t.Fatalf("partial file left behind: %v", err)
			}
		})
	}
}

func TestCaptureArgumentsAndWriteErrors(t *testing.T) {
	fn := func(context.Context, windowsaudio.Config) (windowsaudio.Report, []byte, error) {
		t.Fatal("invalid arguments opened a device")
		return windowsaudio.Report{}, nil, nil
	}
	for _, args := range [][]string{{"--duration", "0s"}, {"--duration", "2m"}, {"--duration", "100.5ms"}, {"extra"}, {"--unknown"}} {
		if runCapture(context.Background(), args, io.Discard, io.Discard, fn) != 2 {
			t.Fatalf("accepted %v", args)
		}
	}
	if err := writeCaptureWAV(shortWriter{}, windowsaudio.Format{SampleRate: 48000, Channels: 2}, 1, make([]byte, 4)); !errors.Is(err, io.ErrShortWrite) {
		t.Fatalf("lost write error: %v", err)
	}
}
