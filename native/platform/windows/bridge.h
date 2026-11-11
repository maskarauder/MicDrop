#ifndef MICDROP_WINDOWS_BRIDGE_H
#define MICDROP_WINDOWS_BRIDGE_H

#include "capture.h"

#ifdef __cplusplus
extern "C" {
#endif

/* Active recording endpoints, for choosing the cable's input in another app.
 * Listing/opening a render stream never opens or records a physical microphone. */
int mdw_input_devices_list(mdw_devices** out, mdw_error* error);

typedef struct mdw_bridge_report {
  mdw_device device;
  uint32_t mix_rate, mix_channels, mix_bits, mix_valid_bits, mix_channel_mask;
  int mix_float;
  uint32_t buffer_frames, maximum_padding_frames;
  int64_t default_period_100ns, stream_latency_100ns;
  uint64_t frames_written, writes, empty_buffer_events;
  double elapsed_ms;
} mdw_bridge_report;

/* Writes synthetic PCM ONLY to an explicit active render endpoint, pinned for
 * the call. Source is 48 kHz stereo float32; shared-mode Windows conversion
 * adapts it to the endpoint mix format. No default fallback or driver install.
 * Pattern: 1s 440Hz, 1s silence, 1s 880Hz, 1s silence, repeating at peak 0.05.
 * Duration is 100..60000 ms of SOURCE audio. Normal completion drains the client
 * queue; cancellation/failure stops and resets it. 0=success, 1=failure, 2=cancel.
 * The caller owns the cancellation token and must join before freeing it. */
int mdw_bridge_check(const char* render_endpoint_id, uint32_t duration_ms,
    mdw_cancel* cancel, mdw_bridge_report* report, mdw_error* error);

/* Live native pull boundary. The call owns COM and the fixed destination until
 * cancellation/failure. Pull writes exactly frames*2 float samples; frames is
 * bounded by a <=100ms client buffer. No callback crosses into Go or retains the
 * borrowed buffer. Gate's low bit enables output; the remaining bits identify
 * control revisions. A change stops/resets the client before applied() runs.
 * While muted, pull still drains the decoder but must write silence. */
typedef int (*mdw_bridge_pull)(void* context, float* stereo, uint32_t frames);
typedef uint64_t (*mdw_bridge_gate)(void* context);
typedef void (*mdw_bridge_applied)(void* context, uint64_t revision);
typedef void (*mdw_bridge_status)(void* context, const mdw_bridge_report* report);
int mdw_bridge_live(const char* render_endpoint_id, mdw_cancel* cancel, void* context,
    mdw_bridge_pull pull, mdw_bridge_gate gate, mdw_bridge_applied applied,
    mdw_bridge_status status, mdw_error* error);

#ifdef __cplusplus
}
#endif
#endif
