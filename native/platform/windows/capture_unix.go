// SPDX-License-Identifier: MPL-2.0
//go:build (linux && amd64) || (darwin && arm64)

package windowsaudio

/*
#cgo CXXFLAGS: -std=c++20 -Wall -Wextra
#cgo linux LDFLAGS: -ldl -lm
#cgo darwin CFLAGS: -Wall -Wextra
#cgo darwin LDFLAGS: -framework CoreAudio -framework AudioToolbox -framework CoreFoundation -framework Foundation
#include <stdlib.h>
#include "capture.h"
*/
import "C"

import (
	"context"
	"errors"
	"time"
	"unsafe"
)

func Available() bool { return true }

func nativeError(err *C.mdw_error) error {
	return &NativeError{Operation: C.GoString(&err.message[0]), HRESULT: uint32(err.hresult)}
}

func deviceFromNative(d *C.mdw_device) Device {
	return Device{ID: C.GoString(&d.id[0]), Name: C.GoString(&d.name[0]), DefaultMultimedia: d.default_multimedia != 0}
}

func Devices() ([]Device, error) {
	var list *C.mdw_devices
	var nativeErr C.mdw_error
	if C.mdw_devices_list(&list, &nativeErr) != 0 {
		return nil, nativeError(&nativeErr)
	}
	defer C.mdw_devices_free(list)
	devices := make([]Device, int(C.mdw_devices_count(list)))
	for i := range devices {
		devices[i] = deviceFromNative(C.mdw_devices_get(list, C.size_t(i)))
	}
	return devices, nil
}

// Capture blocks for a short diagnostic run, then copies the optional PCM16
// recording out of native memory. Go performs no live per-packet work.
func Capture(ctx context.Context, config Config) (Report, []byte, error) {
	if err := config.Validate(); err != nil {
		return Report{}, nil, err
	}
	if err := ctx.Err(); err != nil {
		return Report{}, nil, err
	}
	cancel := C.mdw_cancel_create()
	if cancel == nil {
		return Report{}, nil, errors.New("create native cancellation event")
	}
	defer C.mdw_cancel_free(cancel)
	id := C.CString(config.EndpointID)
	defer C.free(unsafe.Pointer(id))
	done, joined := make(chan struct{}), make(chan struct{})
	go func() {
		defer close(joined)
		select {
		case <-ctx.Done():
			C.mdw_cancel_request(cancel)
		case <-done:
		}
	}()
	var r C.mdw_report
	var recording *C.mdw_recording
	var nativeErr C.mdw_error
	var record C.int
	if config.Record {
		record = 1
	}
	result := C.mdw_capture_run(id, C.uint32_t(config.Duration/time.Millisecond), record, cancel, &r, &recording, &nativeErr)
	close(done)
	<-joined
	defer C.mdw_recording_free(recording)
	if err := ctx.Err(); err != nil {
		return Report{}, nil, err
	}
	if result == 2 {
		return Report{}, nil, context.Canceled
	}
	if result != 0 {
		return Report{}, nil, nativeError(&nativeErr)
	}
	encoding := "pcm_signed"
	if r.float_source != 0 {
		encoding = "float32"
	}
	report := Report{
		Device:              deviceFromNative(&r.device),
		Format:              Format{uint32(r.sample_rate), uint32(r.channels), encoding, uint32(r.container_bits), uint32(r.valid_bits), uint32(r.channel_mask)},
		RequestedDurationMS: config.Duration.Milliseconds(), ElapsedMS: float64(r.elapsed_ms),
		AudioDurationMS: float64(r.frames) * 1000 / float64(r.sample_rate),
		BufferFrames:    uint32(r.buffer_frames), DefaultPeriodMS: float64(r.default_period_100ns) / 10000,
		MinimumPeriodMS: float64(r.minimum_period_100ns) / 10000,
		Frames:          uint64(r.frames), Packets: uint64(r.packets),
		MinPacketFrames: uint32(r.min_packet_frames), MaxPacketFrames: uint32(r.max_packet_frames),
		SilentFlagFrames: uint64(r.silent_flag_frames), Discontinuities: uint64(r.discontinuities),
		FirstPacketDiscontinuity: r.first_packet_discontinuity != 0,
		TimestampErrors:          uint64(r.timestamp_errors), PositionGapFrames: uint64(r.position_gap_frames),
		PositionRegressions: uint64(r.position_regressions), ValidTimestamps: uint64(r.valid_timestamps),
		FirstDeviceFrame: uint64(r.first_device_frame), LastDeviceFrame: uint64(r.last_device_frame),
		FirstQPC100ns: uint64(r.first_qpc_100ns), LastQPC100ns: uint64(r.last_qpc_100ns),
		NonfiniteSamples: uint64(r.nonfinite_samples), AboveFullScaleSamples: uint64(r.clipped_samples),
		Levels: make([]Level, int(r.channels)),
	}
	for i := range report.Levels {
		report.Levels[i] = Level{Peak: float64(r.peak[i]), RMS: float64(r.rms[i])}
	}
	var pcm []byte
	if config.Record {
		pcm = C.GoBytes(unsafe.Pointer(C.mdw_recording_data(recording)), C.int(C.mdw_recording_size(recording)))
	}
	return report, pcm, nil
}
