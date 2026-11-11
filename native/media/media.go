// Package media exposes the native test source to offline host diagnostics.
// Real-time device callbacks must stay in native code; Render allocates Go memory.
package media

/*
#cgo CXXFLAGS: -std=c++20 -Wall -Wextra
#cgo linux LDFLAGS: -lstdc++ -lm
#cgo windows LDFLAGS: -static -lstdc++ -lm
#cgo darwin LDFLAGS: -lc++
#include "capi.h"
*/
import "C"

import (
	"errors"
	"fmt"
	"sync"
	"unsafe"
)

const MaxBlockFrames = 4096

func ABIVersion() uint32 { return uint32(C.md_abi_version()) }

type ToneConfig struct {
	SampleRate int
	Channels   int
	Frequency  float32
	Amplitude  float32
}

// Tone owns a native handle. Close it after use. Do not copy a Tone.
type Tone struct {
	mu       sync.Mutex
	handle   *C.md_tone
	channels int
}

func NewTone(config ToneConfig) (*Tone, error) {
	if config.SampleRate < 8000 || config.SampleRate > 192000 || config.Channels < 1 || config.Channels > 2 {
		return nil, errors.New("unsupported tone sample rate or channel count")
	}
	native := C.md_tone_config{
		sample_rate: C.uint32_t(config.SampleRate), channels: C.uint32_t(config.Channels),
		frequency_hz: C.float(config.Frequency), amplitude: C.float(config.Amplitude),
	}
	var handle *C.md_tone
	if result := C.md_tone_create(&native, &handle); result != C.MD_OK {
		return nil, fmt.Errorf("native tone creation failed: %d", result)
	}
	return &Tone{handle: handle, channels: config.Channels}, nil
}

func (t *Tone) Close() {
	t.mu.Lock()
	defer t.mu.Unlock()
	C.md_tone_destroy(t.handle)
	t.handle = nil
}

func (t *Tone) Render(frames int) ([]float32, error) {
	t.mu.Lock()
	defer t.mu.Unlock()
	if t.handle == nil {
		return nil, errors.New("tone is closed")
	}
	if frames < 1 || frames > MaxBlockFrames {
		return nil, fmt.Errorf("frame count must be between 1 and %d", MaxBlockFrames)
	}
	samples := make([]float32, frames*t.channels)
	// The native function does not retain the pointer into Go memory.
	result := C.md_tone_render(t.handle, (*C.float)(unsafe.Pointer(&samples[0])), C.size_t(len(samples)), C.uint32_t(frames))
	if result != C.MD_OK {
		return nil, fmt.Errorf("native tone render failed: %d", result)
	}
	return samples, nil
}
