#ifndef MICDROP_WINDOWS_CAPTURE_H
#define MICDROP_WINDOWS_CAPTURE_H

#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

/* Experimental, one-shot diagnostic API. No Windows types cross this boundary.
 * All COM/audio work stays inside one synchronous native call. No Go callbacks,
 * file I/O, or allocation occurs while servicing capture packets.
 * Error text and endpoint strings are UTF-8. IDs are never silently truncated.
 */
enum { MDW_MAX_CHANNELS = 32 };
typedef struct mdw_error { int32_t hresult; char message[256]; } mdw_error;
typedef struct mdw_device {
  char id[1024];
  char name[512];
  int default_multimedia;
} mdw_device;
typedef struct mdw_devices mdw_devices;

int mdw_devices_list(mdw_devices** out, mdw_error* error);
size_t mdw_devices_count(const mdw_devices* devices);
const mdw_device* mdw_devices_get(const mdw_devices* devices, size_t index);
void mdw_devices_free(mdw_devices* devices);

typedef struct mdw_cancel mdw_cancel;
mdw_cancel* mdw_cancel_create(void);
/* May be called concurrently with run. Join the caller before freeing token. */
void mdw_cancel_request(mdw_cancel* cancel);
void mdw_cancel_free(mdw_cancel* cancel);

typedef struct mdw_report {
  mdw_device device;
  uint32_t sample_rate, channels, container_bits, valid_bits, channel_mask;
  int float_source;
  uint32_t buffer_frames, min_packet_frames, max_packet_frames;
  int64_t default_period_100ns, minimum_period_100ns;
  double elapsed_ms;
  uint64_t frames, packets, silent_flag_frames;
  uint64_t discontinuities, timestamp_errors, position_gap_frames, position_regressions;
  int first_packet_discontinuity;
  uint64_t valid_timestamps, first_device_frame, last_device_frame;
  uint64_t first_qpc_100ns, last_qpc_100ns;
  uint64_t nonfinite_samples, clipped_samples;
  double peak[MDW_MAX_CHANNELS], rms[MDW_MAX_CHANNELS];
} mdw_report;
typedef struct mdw_recording mdw_recording;

/* Empty endpoint ID selects the current default multimedia render endpoint ONCE.
 * It stays pinned to that endpoint. Invalidation fails without switching devices.
 * Duration: 100..60000 ms of wall time. store_pcm=0 stores no recording.
 * Recording storage is preallocated and capped at 64 MiB; full capacity is an
 * error, never silent truncation. Delivered packets are concatenated (no gap
 * padding). PCM16 output retains the source rate, channels and channel mask.
 * Returns 0 on success, 1 on failure, 2 on cancellation. out stays NULL on failure.
 * report remains available on failure, but only success finalizes RMS/timing.
 * run borrows cancel; destroy it only after run and any request have returned.
 */
int mdw_capture_run(const char* endpoint_id, uint32_t duration_ms, int store_pcm,
                    mdw_cancel* cancel, mdw_report* report,
                    mdw_recording** out, mdw_error* error);
const uint8_t* mdw_recording_data(const mdw_recording* recording);
size_t mdw_recording_size(const mdw_recording* recording);
void mdw_recording_free(mdw_recording* recording);

/* Native streaming sink: called on the capture thread after ReleaseBuffer.
 * format runs before Start and may allocate. packet must be bounded, must not
 * retain the borrowed float buffer, and must not call Go/JNI or perform I/O.
 * A nonzero callback return stops capture with an error. Cancellation returns 2.
 */
typedef int (*mdw_format_sink)(void* context, const mdw_report* format);
typedef int (*mdw_packet_sink)(void* context, const float* pcm, uint32_t frames, uint32_t flags);
int mdw_capture_live(const char* endpoint_id, mdw_cancel* cancel, void* context,
                     mdw_format_sink format, mdw_packet_sink packet, mdw_error* error);

#ifdef __cplusplus
}
#endif
#endif
