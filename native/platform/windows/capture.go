// Package windowsaudio provides Windows loopback capture and an explicit-output
// virtual-input bridge diagnostic. Native code owns live audio servicing.
package windowsaudio

import (
	"errors"
	"fmt"
	"strings"
	"time"
	"unicode/utf8"
)

var ErrUnsupported = errors.New("WASAPI audio requires Windows; this build only supports offline contract checks")

type Device struct {
	ID                string `json:"id"`
	Name              string `json:"name"`
	DefaultMultimedia bool   `json:"default_multimedia"`
}

type Config struct {
	EndpointID string // Empty selects the default multimedia output once at start.
	Duration   time.Duration
	Record     bool // Retain PCM only with explicit recording intent.
}

func (c Config) Validate() error {
	if c.Duration < 100*time.Millisecond || c.Duration > time.Minute || c.Duration%time.Millisecond != 0 {
		return errors.New("capture duration must be 100ms through 1m in whole milliseconds")
	}
	if len(c.EndpointID) > 1023 || strings.ContainsRune(c.EndpointID, 0) || !utf8.ValidString(c.EndpointID) {
		return errors.New("invalid UTF-8 endpoint ID")
	}
	return nil
}

type Format struct {
	SampleRate    uint32 `json:"sample_rate_hz"`
	Channels      uint32 `json:"channels"`
	Encoding      string `json:"source_encoding"`
	ContainerBits uint32 `json:"container_bits"`
	ValidBits     uint32 `json:"valid_bits"`
	ChannelMask   uint32 `json:"channel_mask"`
}

type Level struct {
	Peak float64 `json:"peak_linear"`
	RMS  float64 `json:"rms_linear"`
}

type Report struct {
	Device                   Device  `json:"device"`
	Format                   Format  `json:"format"`
	RequestedDurationMS      int64   `json:"requested_duration_ms"`
	ElapsedMS                float64 `json:"elapsed_ms"`
	AudioDurationMS          float64 `json:"delivered_audio_ms"`
	BufferFrames             uint32  `json:"endpoint_buffer_frames"`
	DefaultPeriodMS          float64 `json:"default_device_period_ms"`
	MinimumPeriodMS          float64 `json:"minimum_device_period_ms"`
	Frames                   uint64  `json:"frames"`
	Packets                  uint64  `json:"packets"`
	MinPacketFrames          uint32  `json:"min_packet_frames"`
	MaxPacketFrames          uint32  `json:"max_packet_frames"`
	SilentFlagFrames         uint64  `json:"silent_flag_frames"`
	Discontinuities          uint64  `json:"discontinuities_after_first_packet"`
	FirstPacketDiscontinuity bool    `json:"first_packet_discontinuity"`
	TimestampErrors          uint64  `json:"timestamp_errors"`
	PositionGapFrames        uint64  `json:"position_gap_frames"`
	PositionRegressions      uint64  `json:"position_regressions"`
	ValidTimestamps          uint64  `json:"valid_timestamps"`
	FirstDeviceFrame         uint64  `json:"first_device_frame"`
	LastDeviceFrame          uint64  `json:"last_device_frame"`
	FirstQPC100ns            uint64  `json:"first_qpc_100ns"`
	LastQPC100ns             uint64  `json:"last_qpc_100ns"`
	NonfiniteSamples         uint64  `json:"nonfinite_samples"`
	AboveFullScaleSamples    uint64  `json:"above_full_scale_samples"`
	Levels                   []Level `json:"channel_levels"`
}

// NativeError retains the operation and HRESULT for actionable device failures.
type NativeError struct {
	Operation string
	HRESULT   uint32
}

func (e *NativeError) Error() string {
	return fmt.Sprintf("%s (HRESULT 0x%08X)", e.Operation, e.HRESULT)
}
