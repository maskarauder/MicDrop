package windowsaudio

/*
#include <stdlib.h>
#include "bridge.h"
*/
import "C"

import (
	"context"
	"errors"
	"time"
	"unsafe"
)

func InputDevices() ([]Device, error) {
	var list *C.mdw_devices
	var nativeErr C.mdw_error
	if C.mdw_input_devices_list(&list, &nativeErr) != 0 {
		return nil, nativeError(&nativeErr)
	}
	defer C.mdw_devices_free(list)
	devices := make([]Device, int(C.mdw_devices_count(list)))
	for i := range devices {
		devices[i] = deviceFromNative(C.mdw_devices_get(list, C.size_t(i)))
	}
	return devices, nil
}

// BridgeCheck owns COM and rendering in one synchronous native call. The only
// concurrent operation is signaling cancellation, joined before freeing it.
func BridgeCheck(ctx context.Context, config BridgeConfig) (BridgeReport, error) {
	if err := config.Validate(); err != nil {
		return BridgeReport{}, err
	}
	if err := ctx.Err(); err != nil {
		return BridgeReport{}, err
	}
	cancel := C.mdw_cancel_create()
	if cancel == nil {
		return BridgeReport{}, errors.New("create native bridge cancellation event")
	}
	defer C.mdw_cancel_free(cancel)
	id := C.CString(config.RenderEndpointID)
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
	var r C.mdw_bridge_report
	var nativeErr C.mdw_error
	result := C.mdw_bridge_check(id, C.uint32_t(config.Duration/time.Millisecond), cancel, &r, &nativeErr)
	close(done)
	<-joined
	if err := ctx.Err(); err != nil {
		return BridgeReport{}, err
	}
	if result == 2 {
		return BridgeReport{}, context.Canceled
	}
	if result != 0 {
		return BridgeReport{}, nativeError(&nativeErr)
	}
	encoding := "pcm_signed"
	if r.mix_float != 0 {
		encoding = "float32"
	}
	return BridgeReport{
		Device:      deviceFromNative(&r.device),
		Source:      Format{SampleRate: 48000, Channels: 2, Encoding: "float32", ContainerBits: 32, ValidBits: 32, ChannelMask: 3},
		EndpointMix: Format{uint32(r.mix_rate), uint32(r.mix_channels), encoding, uint32(r.mix_bits), uint32(r.mix_valid_bits), uint32(r.mix_channel_mask)},
		RequestedMS: config.Duration.Milliseconds(), ElapsedMS: float64(r.elapsed_ms),
		Frames: uint64(r.frames_written), Writes: uint64(r.writes),
		BufferFrames: uint32(r.buffer_frames), MaximumPadding: uint32(r.maximum_padding_frames),
		DefaultPeriodMS:   float64(r.default_period_100ns) / 10000,
		OSStreamLatencyMS: float64(r.stream_latency_100ns) / 10000,
		EmptyBufferEvents: uint64(r.empty_buffer_events),
	}, nil
}
