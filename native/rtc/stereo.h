#ifndef MICDROP_RTC_STEREO_H
#define MICDROP_RTC_STEREO_H
#include <array>
#include <bit>
#include <cmath>
#include <cstddef>
#include <cstdint>

namespace micdrop {
// Windows speaker-mask order is ascending bit order. Unknown layouts fail;
// never silently assume the first two channels represent the complete mix.
class StereoMatrix {
 public:
  bool Configure(uint32_t channels, uint32_t mask) {
    valid_ = false;
    coefficients_ = {};
    if (channels == 1 && (mask == 0 || mask == 4)) {
      coefficients_[0] = {1, 1};
    } else if (channels == 2 && (mask == 0 || mask == 3)) {
      coefficients_[0] = {1, 0}; coefficients_[1] = {0, 1};
    } else {
      if (!mask || (mask & ~uint32_t{0x7ff}) || std::popcount(mask) != static_cast<int>(channels)) return false;
      constexpr float surround = 0.70710678118f;
      constexpr std::array<std::array<float, 2>, 11> weights{{
          {1,0}, {0,1}, {surround,surround}, {0,0}, // front L/R, center, LFE
          {surround,0}, {0,surround}, {surround,0}, {0,surround}, // back and front-center L/R
          {0.5f,0.5f}, {surround,0}, {0,surround}}}; // back center, side L/R
      size_t channel = 0;
      for (uint32_t bit = 0; bit < weights.size(); ++bit)
        if (mask & (uint32_t{1} << bit)) coefficients_[channel++] = weights[bit];
    }
    channels_ = channels; valid_ = true; return true;
  }
  // The caller clamps/quantizes after mixing. Front L/R stay at unity gain;
  // center/surround contribute at the documented weights; LFE is omitted.
  std::array<float, 2> Mix(const float* frame) const {
    std::array<float, 2> result{};
    if (!valid_) return result;
    for (uint32_t i = 0; i < channels_; ++i) {
      const float value = std::isfinite(frame[i]) ? frame[i] : 0;
      result[0] += value * coefficients_[i][0];
      result[1] += value * coefficients_[i][1];
    }
    return result;
  }
 private:
  bool valid_ = false;
  uint32_t channels_ = 0;
  std::array<std::array<float, 2>, 32> coefficients_{};
};
}  // namespace micdrop
#endif
