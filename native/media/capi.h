#ifndef MICDROP_MEDIA_CAPI_H
#define MICDROP_MEDIA_CAPI_H

#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

/* Internal ABI for tone diagnostics, not a network protocol or stable SDK. */
#define MD_ABI_VERSION 1u

typedef enum md_result {
  MD_OK = 0,
  MD_INVALID_ARGUMENT = 1,
  MD_OUT_OF_MEMORY = 2
} md_result;

typedef struct md_tone md_tone;

typedef struct md_tone_config {
  uint32_t sample_rate; /* 8000..192000 Hz */
  uint32_t channels;    /* 1 or 2; interleaved, identical channels */
  float frequency_hz;   /* finite, > 0 and < sample_rate / 2 */
  float amplitude;      /* finite, 0..1 */
} md_tone_config;

uint32_t md_abi_version(void);

/* Create/destroy on a control thread. The caller owns the returned handle.
 * On failure, *out_tone is NULL. No C++ objects/exceptions cross this interface. */
md_result md_tone_create(const md_tone_config* config, md_tone** out_tone);
void md_tone_destroy(md_tone* tone);

/* Allocation-free rendering, bounded by frame_count, with phase continuity.
 * Capacity is in float samples, NOT frames. Invalid arguments leave both the
 * output and generator state unchanged. A zero-frame call may use NULL output.
 * Serialize calls on each handle; never destroy while rendering. Memory is
 * borrowed only for this call. This generator is a test source, not a codec. */
md_result md_tone_render(md_tone* tone, float* output,
                         size_t capacity_samples, uint32_t frame_count);

#ifdef __cplusplus
}
#endif
#endif
