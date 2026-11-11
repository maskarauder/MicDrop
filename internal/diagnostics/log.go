package diagnostics

import (
	"encoding/json"
	"errors"
	"io"
	"os"
	"path/filepath"
	"runtime"
	"runtime/debug"
	"sync"
	"time"

	"github.com/maskarauder/MicDrop/internal/rtc"
	"github.com/maskarauder/MicDrop/internal/version"
)

const maxLogBytes = 16 * 1024 * 1024

type Source uint8

const (
	DesktopCapture Source = iota
	StereoProbe
	PhoneMicrophone
	DuplexCapture
	DuplexProbe
)

type record struct {
	Type      string         `json:"type"`
	HostTime  time.Time      `json:"host_time"`
	ElapsedMS int64          `json:"host_elapsed_ms"`
	Windows   *rtc.Status    `json:"windows,omitempty"`
	Android   *AndroidReport `json:"android,omitempty"`
	Details   any            `json:"details,omitempty"`
}

type Log struct {
	mu          sync.Mutex
	queue       chan record
	done        chan struct{}
	started     time.Time
	state       string
	dropped     uint64
	closed      bool
	reason      string
	receiverEnd *record
}

// Create opens a new file exclusively. A queue separates disk I/O from status
// heartbeats and audio. Records are written as JSON Lines for crash recovery.
func Create(path string, source Source, now time.Time) (*Log, string, error) {
	if path == "" {
		return CreateInDirectory("diagnostics-private", source, now)
	}
	file, err := os.OpenFile(path, os.O_WRONLY|os.O_CREATE|os.O_EXCL, 0600)
	if err != nil {
		return nil, "", err
	}
	return startFile(file, source, now)
}

// CreateInDirectory creates one unique file per accepted session, never an
// empty idle-host log and never overwriting a previous session's diagnostics.
func CreateInDirectory(directory string, source Source, now time.Time) (*Log, string, error) {
	if err := os.MkdirAll(directory, 0700); err != nil {
		return nil, "", err
	}
	file, err := os.CreateTemp(directory, "micdrop-"+now.UTC().Format("20060102T150405Z")+"-*.jsonl")
	if err != nil {
		return nil, "", err
	}
	return startFile(file, source, now)
}

func startFile(file *os.File, source Source, now time.Time) (*Log, string, error) {
	abs, err := filepath.Abs(file.Name())
	if err != nil {
		_ = file.Close()
		return nil, "", err
	}
	trackLog(abs, true)
	l := newLog(file, maxLogBytes, now)
	revision, modified := "unavailable", false
	if info, ok := debug.ReadBuildInfo(); ok {
		for _, setting := range info.Settings {
			if setting.Key == "vcs.revision" {
				revision = setting.Value
			}
			if setting.Key == "vcs.modified" {
				modified = setting.Value == "true"
			}
		}
	}
	sourceName, direction, microphone, playback := "desktop_capture", "desktop_playback", "off", "receiver_managed"
	if source == StereoProbe {
		sourceName = "stereo_probe"
	} else if source == PhoneMicrophone {
		sourceName, direction, microphone, playback = "phone_microphone", "phone_microphone", "requested", "off"
	} else if source == DuplexCapture || source == DuplexProbe {
		direction, microphone = "duplex", "requested"
		if source == DuplexProbe {
			sourceName = "stereo_probe"
		}
	}
	l.submit(record{Type: "session_start", Details: map[string]any{
		"schema_version": 1, "platform": runtime.GOOS + "/" + runtime.GOARCH,
		"app_version": version.Current().Version, "go_version": runtime.Version(), "revision": revision, "modified": modified,
		"source": sourceName, "audio_direction": direction,
		"phone_microphone": microphone, "playback": playback, "limit_bytes": maxLogBytes,
		"timing": "Host and Android clocks are not synchronized; timestamps do not measure audio latency.",
	}})
	return l, abs, nil
}

func newLog(writer io.WriteCloser, limit int, now time.Time) *Log {
	l := &Log{queue: make(chan record, 64), done: make(chan struct{}), started: now, state: "active"}
	go l.write(writer, limit)
	return l
}

// Submit takes ownership of its immutable snapshot. A full queue drops a report
// rather than delaying the control connection. The terminal record counts drops.
func (l *Log) submit(entry record) string {
	if l == nil {
		return "disabled"
	}
	l.mu.Lock()
	defer l.mu.Unlock()
	if l.closed {
		return "closed"
	}
	if l.state != "active" {
		return l.state
	}
	entry.HostTime = time.Now().UTC()
	entry.ElapsedMS = time.Since(l.started).Milliseconds()
	select {
	case l.queue <- entry:
		return "accepted"
	default:
		l.dropped++
		return "busy"
	}
}

func (l *Log) Host(status rtc.Status) { l.submit(record{Type: "windows_status", Windows: &status}) }
func (l *Log) OfferFailure(err error) {
	l.submit(record{Type: "offer_failure", Details: rtc.DescribeOfferFailure(err)})
}
func (l *Log) Playback(status rtc.Status, report *AndroidReport) string {
	return l.submit(record{Type: "playback", Windows: &status, Android: report})
}

// Reserve one terminal snapshot independently of the lossy periodic queue. It
// is emitted immediately before session_end, including when the normal log is
// full. Acceptance is not a guarantee against disk failure or process death.
func (l *Log) ReceiverEnd(status *rtc.Status, report *ReceiverEnd) string {
	if l == nil {
		return "disabled"
	}
	l.mu.Lock()
	defer l.mu.Unlock()
	if l.closed {
		return "closed"
	}
	if l.state == "unavailable" {
		return l.state
	}
	l.receiverEnd = &record{Type: "receiver_end", HostTime: time.Now().UTC(),
		ElapsedMS: time.Since(l.started).Milliseconds(), Windows: status, Details: report}
	return "accepted"
}

func (l *Log) State() string {
	if l == nil {
		return "disabled"
	}
	l.mu.Lock()
	defer l.mu.Unlock()
	if l.closed && l.state == "active" {
		return "closed"
	}
	return l.state
}

// Close drains pending records, adds a session end and syncs the file. A stalled
// filesystem cannot keep audio shutdown waiting indefinitely.
func (l *Log) Close(reason string) error {
	if l == nil {
		return nil
	}
	l.mu.Lock()
	if !l.closed {
		l.closed = true
		l.reason = reason
		close(l.queue)
	}
	l.mu.Unlock()
	select {
	case <-l.done:
		if l.State() == "unavailable" {
			return errors.New("combined log write failed; use Android's copy report fallback")
		}
		return nil
	case <-time.After(2 * time.Second):
		return errors.New("combined log finalization timed out; the last records may be missing")
	}
}

func (l *Log) write(writer io.WriteCloser, limit int) {
	defer close(l.done)
	if file, ok := writer.(*os.File); ok {
		path, _ := filepath.Abs(file.Name())
		defer trackLog(path, false)
	}
	failed := false
	setState := func(state string) { l.mu.Lock(); l.state = state; l.mu.Unlock() }
	written := 0
	write := func(entry record) {
		if failed {
			return
		}
		data, err := json.Marshal(entry)
		if err == nil {
			data = append(data, '\n')
			var n int
			n, err = writer.Write(data)
			if err == nil && n != len(data) {
				err = io.ErrShortWrite
			}
			written += n
		}
		if err != nil {
			failed = true
			setState("unavailable")
		}
	}
	full := false
	// Enough room for the 8 KiB terminal request, a Windows status and footer.
	// Small limits used in tests retain the original half-file reserve.
	reserve := min(16*1024, limit/2)
	for entry := range l.queue {
		if failed || full {
			continue
		}
		data, err := json.Marshal(entry)
		if err != nil {
			failed = true
			setState("unavailable")
			continue
		}
		if written+len(data)+1 > limit-reserve {
			full = true
			setState("full")
			write(record{Type: "log_limit", HostTime: time.Now().UTC(), ElapsedMS: time.Since(l.started).Milliseconds()})
			continue
		}
		write(entry)
	}
	l.mu.Lock()
	reason, dropped, receiverEnd := l.reason, l.dropped, l.receiverEnd
	l.mu.Unlock()
	terminalWritten := false
	if receiverEnd != nil {
		data, err := json.Marshal(receiverEnd)
		if err == nil && written+len(data)+1 <= limit-1024 {
			write(*receiverEnd)
			terminalWritten = !failed
		}
	}
	write(record{Type: "session_end", HostTime: time.Now().UTC(), ElapsedMS: time.Since(l.started).Milliseconds(),
		Details: map[string]any{"reason": reason, "dropped_records": dropped, "size_limit_reached": full,
			"receiver_diagnostics_written": terminalWritten}})
	if file, ok := writer.(*os.File); ok {
		if err := file.Sync(); err != nil {
			setState("unavailable")
		}
	}
	if err := writer.Close(); err != nil {
		setState("unavailable")
	}
}
