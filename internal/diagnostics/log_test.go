package diagnostics

import (
	"bytes"
	"encoding/json"
	"errors"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"

	"github.com/maskarauder/MicDrop/internal/rtc"
)

type memoryLog struct{ bytes.Buffer }

func (*memoryLog) Close() error { return nil }

func readRecords(t *testing.T, data []byte) []record {
	t.Helper()
	var entries []record
	for _, line := range bytes.Split(bytes.TrimSpace(data), []byte("\n")) {
		var entry record
		if err := json.Unmarshal(line, &entry); err != nil {
			t.Fatal(err)
		}
		entries = append(entries, entry)
	}
	return entries
}

func TestCombinedFileAndNoOverwrite(t *testing.T) {
	path := filepath.Join(t.TempDir(), "session.jsonl")
	l, actual, err := Create(path, DesktopCapture, time.Now())
	if err != nil || actual != path {
		t.Fatalf("create: %s %v", actual, err)
	}
	status := rtc.Status{State: "connected", BytesSent: 1234}
	report := &AndroidReport{Sequence: 1, CapturedAt: time.Now().UTC(), State: "Connected"}
	l.Host(status)
	if l.Playback(status, report) != "accepted" {
		t.Fatal("upload was not queued")
	}
	if err := l.Close("receiver_stop"); err != nil {
		t.Fatal(err)
	}
	data, err := os.ReadFile(path)
	if err != nil {
		t.Fatal(err)
	}
	entries := readRecords(t, data)
	if len(entries) != 4 || entries[0].Type != "session_start" || entries[1].Type != "windows_status" ||
		entries[2].Windows.BytesSent != 1234 || entries[2].Android.Sequence != 1 || entries[3].Type != "session_end" {
		t.Fatalf("incomplete log: %s", data)
	}
	if !strings.Contains(string(data), "receiver_stop") || l.Playback(status, report) != "closed" {
		t.Fatal("close did not finish the log")
	}
	if other, _, err := Create(path, DesktopCapture, time.Now()); err == nil {
		_ = other.Close("test")
		t.Fatal("overwrote log")
	}
	after, _ := os.ReadFile(path)
	if !bytes.Equal(data, after) {
		t.Fatal("modified existing log")
	}
}

func TestLogSizeLimitLeavesReadableEnd(t *testing.T) {
	writer := &memoryLog{}
	l := newLog(writer, 2048, time.Now())
	for i := 0; i < 50; i++ {
		l.Host(rtc.Status{State: "connected"})
	}
	if err := l.Close("host_stopped"); err != nil {
		t.Fatal(err)
	}
	entries := readRecords(t, writer.Bytes())
	if l.State() != "full" || writer.Len() > 2048 || entries[len(entries)-1].Type != "session_end" || !strings.Contains(writer.String(), "log_limit") {
		t.Fatalf("unbounded/truncated log: %s", writer.String())
	}
}

type brokenLog struct{ short bool }

func (w brokenLog) Write(data []byte) (int, error) {
	if w.short {
		return len(data) - 1, nil
	}
	return 0, errors.New("disk failed")
}
func (brokenLog) Close() error { return nil }

func TestWriteErrorsAreReportedWithoutBlockingProducer(t *testing.T) {
	for _, short := range []bool{false, true} {
		l := newLog(brokenLog{short: short}, maxLogBytes, time.Now())
		l.Host(rtc.Status{State: "connected"})
		if err := l.Close("host_stopped"); err == nil || l.State() != "unavailable" {
			t.Fatal("lost disk failure")
		}
	}
}

type blockedLog struct {
	entered, release chan struct{}
	memoryLog
}

func (w *blockedLog) Write(data []byte) (int, error) {
	select {
	case w.entered <- struct{}{}:
	default:
	}
	<-w.release
	return w.memoryLog.Write(data)
}

func TestSlowDiskHasBoundedQueueAndCountsLoss(t *testing.T) {
	w := &blockedLog{entered: make(chan struct{}, 1), release: make(chan struct{})}
	l := newLog(w, maxLogBytes, time.Now())
	l.Host(rtc.Status{})
	select {
	case <-w.entered:
	case <-time.After(time.Second):
		t.Fatal("writer did not start")
	}
	for i := 0; i < 64; i++ {
		if l.Playback(rtc.Status{}, nil) != "accepted" {
			t.Fatal("queue unexpectedly full")
		}
	}
	result := make(chan string, 1)
	go func() { result <- l.Playback(rtc.Status{}, nil) }()
	select {
	case state := <-result:
		if state != "busy" {
			t.Fatal("queue was unbounded")
		}
	case <-time.After(time.Second):
		t.Fatal("producer blocked behind disk")
	}
	close(w.release)
	if err := l.Close("host_stopped"); err != nil {
		t.Fatal(err)
	}
	if !strings.Contains(w.String(), `"dropped_records":1`) {
		t.Fatal("missing loss count")
	}
}

func TestDisabledLog(t *testing.T) {
	var l *Log
	l.Host(rtc.Status{})
	if l.Playback(rtc.Status{}, nil) != "disabled" || l.State() != "disabled" || l.Close("host_stopped") != nil {
		t.Fatal("disabled logging interfered")
	}
}

func TestDefaultLogsHaveDistinctNames(t *testing.T) {
	t.Chdir(t.TempDir())
	now := time.Now()
	first, firstPath, err := Create("", DesktopCapture, now)
	if err != nil {
		t.Fatal(err)
	}
	defer first.Close("test")
	second, secondPath, err := Create("", DesktopCapture, now)
	if err != nil {
		t.Fatal(err)
	}
	defer second.Close("test")
	if firstPath == secondPath || filepath.Base(filepath.Dir(firstPath)) != "diagnostics-private" {
		t.Fatal("default paths were not unique/private")
	}
}

func TestSessionSourceMetadata(t *testing.T) {
	for _, tc := range []struct {
		source                                Source
		name, direction, microphone, playback string
	}{
		{DesktopCapture, "desktop_capture", "desktop_playback", "off", "receiver_managed"},
		{StereoProbe, "stereo_probe", "desktop_playback", "off", "receiver_managed"},
		{PhoneMicrophone, "phone_microphone", "phone_microphone", "requested", "off"},
		{DuplexCapture, "desktop_capture", "duplex", "requested", "receiver_managed"},
		{DuplexProbe, "stereo_probe", "duplex", "requested", "receiver_managed"},
	} {
		t.Run(tc.name, func(t *testing.T) {
			l, path, err := CreateInDirectory(t.TempDir(), tc.source, time.Now())
			if err != nil {
				t.Fatal(err)
			}
			if err := l.Close("test"); err != nil {
				t.Fatal(err)
			}
			data, err := os.ReadFile(path)
			if err != nil {
				t.Fatal(err)
			}
			entries := readRecords(t, data)
			start := entries[0].Details.(map[string]any)
			if start["source"] != tc.name || start["audio_direction"] != tc.direction ||
				start["phone_microphone"] != tc.microphone || start["playback"] != tc.playback {
				t.Fatalf("incorrect source metadata: %s", data)
			}
		})
	}
}
