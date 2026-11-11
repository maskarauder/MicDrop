#include "capi.h"

#include <cmath>
#include <new>

namespace {
constexpr double kTau = 6.283185307179586476925286766559;
}

struct md_tone {
  md_tone_config config;
  double phase = 0.0;
};

extern "C" uint32_t md_abi_version(void) { return MD_ABI_VERSION; }

extern "C" md_result md_tone_create(const md_tone_config* config,
                                     md_tone** out_tone) {
  if (out_tone == nullptr) return MD_INVALID_ARGUMENT;
  *out_tone = nullptr;
  if (config == nullptr || config->sample_rate < 8000 ||
      config->sample_rate > 192000 || config->channels < 1 ||
      config->channels > 2 || !std::isfinite(config->frequency_hz) ||
      config->frequency_hz <= 0.0f ||
      config->frequency_hz >= static_cast<float>(config->sample_rate) / 2.0f ||
      !std::isfinite(config->amplitude) || config->amplitude < 0.0f ||
      config->amplitude > 1.0f) {
    return MD_INVALID_ARGUMENT;
  }
  *out_tone = new (std::nothrow) md_tone{*config};
  return *out_tone == nullptr ? MD_OUT_OF_MEMORY : MD_OK;
}

extern "C" void md_tone_destroy(md_tone* tone) { delete tone; }

extern "C" md_result md_tone_render(md_tone* tone, float* output,
                                     size_t capacity_samples,
                                     uint32_t frame_count) {
  if (tone == nullptr) return MD_INVALID_ARGUMENT;
  if (frame_count == 0) return MD_OK;
  if (output == nullptr || frame_count > capacity_samples / tone->config.channels) {
    return MD_INVALID_ARGUMENT;
  }
  const double step = kTau * tone->config.frequency_hz / tone->config.sample_rate;
  for (uint32_t frame = 0; frame < frame_count; ++frame) {
    const float sample = static_cast<float>(std::sin(tone->phase)) * tone->config.amplitude;
    for (uint32_t channel = 0; channel < tone->config.channels; ++channel) {
      output[static_cast<size_t>(frame) * tone->config.channels + channel] = sample;
    }
    tone->phase += step;
    if (tone->phase >= kTau) tone->phase -= kTau;
  }
  return MD_OK;
}
