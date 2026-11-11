package windowsaudio

import (
	"errors"
	"strings"
	"time"
)

type BridgeConfig struct {
	RenderEndpointID string
	Duration         time.Duration
}

func (c BridgeConfig) Validate() error {
	if strings.TrimSpace(c.RenderEndpointID) == "" {
		return errors.New("bridge-check requires --render-device; choose an explicit cable render endpoint from bridge-devices")
	}
	if c.Duration < 100*time.Millisecond || c.Duration > time.Minute || c.Duration%time.Millisecond != 0 {
		return errors.New("bridge-check duration must be 100ms through 1m in whole milliseconds")
	}
	return (Config{EndpointID: c.RenderEndpointID, Duration: c.Duration}).Validate()
}

type BridgeReport struct {
	Device            Device  `json:"render_device"`
	Source            Format  `json:"source_format"`
	EndpointMix       Format  `json:"endpoint_mix_format"`
	RequestedMS       int64   `json:"requested_source_duration_ms"`
	ElapsedMS         float64 `json:"elapsed_ms"`
	Frames            uint64  `json:"submitted_frames"`
	Writes            uint64  `json:"buffer_writes"`
	BufferFrames      uint32  `json:"buffer_capacity_frames"`
	MaximumPadding    uint32  `json:"maximum_observed_padding_frames"`
	DefaultPeriodMS   float64 `json:"default_device_period_ms"`
	OSStreamLatencyMS float64 `json:"os_stream_latency_ms"`
	EmptyBufferEvents uint64  `json:"empty_queue_observations_while_feeding"`
}
