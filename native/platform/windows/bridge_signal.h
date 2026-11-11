#ifndef MICDROP_WINDOWS_BRIDGE_SIGNAL_H
#define MICDROP_WINDOWS_BRIDGE_SIGNAL_H

#include <algorithm>
#include <cmath>
#include <cstddef>
#include <cstdint>
#include <cstring>
#include <limits>

namespace micdrop::bridge_signal {
inline constexpr uint32_t rate = 48000, channels = 2;
inline constexpr size_t frame_bytes = channels * sizeof(float);

// Absolute source frame positions keep the pattern identical across packet
// boundaries. Fill a borrowed buffer without allocation, callbacks or I/O.
inline bool fill(uint8_t* output, size_t bytes, uint64_t first, uint32_t frames) {
  if (!output || !frames || frames > bytes / frame_bytes ||
      first > std::numeric_limits<uint64_t>::max() - frames) return false;
  constexpr double pi = 3.14159265358979323846;
  for (uint32_t i = 0; i < frames; ++i) {
    const auto position = static_cast<uint32_t>((first + i) % (4 * rate));
    const uint32_t local = position % rate;
    float sample = 0;
    if (position / rate % 2 == 0) {
      const double frequency = position < rate ? 440.0 : 880.0;
      const double envelope = std::min({1.0, double(local) / 240.0, double(rate - local) / 240.0});
      sample = static_cast<float>(0.05 * envelope * std::sin(2 * pi * frequency * local / rate));
    }
    for (uint32_t channel = 0; channel < channels; ++channel)
      std::memcpy(output + (static_cast<size_t>(i) * channels + channel) * sizeof(float), &sample, sizeof(sample));
  }
  return true;
}
}  // namespace micdrop::bridge_signal
#endif
