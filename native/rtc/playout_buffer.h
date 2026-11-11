#ifndef MICDROP_RTC_PLAYOUT_BUFFER_H
#define MICDROP_RTC_PLAYOUT_BUFFER_H
#include <algorithm>
#include <array>
#include <cstddef>
#include <cstdint>

namespace micdrop {
// One preallocated 10ms block. The endpoint's clock drives decoder pulls; no
// second jitter buffer or accumulating PCM queue is added. A gate revision
// discards the partial block so old speech cannot survive mute/unmute.
class PlayoutBuffer {
 public:
  template<typename Pull> bool Fill(float* out, uint32_t frames, uint64_t gate, Pull&& pull) {
    if (!out || !frames || frames > 4800) return false;
    if (gate != revision_) { revision_ = gate; position_ = 480; }
    for (uint32_t frame = 0; frame < frames; ++frame) {
      if (position_ == 480) {
        samples_.fill(0);
        if (!pull(samples_.data())) return false;
        position_ = 0;
      }
      const bool enabled = (gate & 1) != 0;
      out[frame * 2] = enabled ? samples_[position_ * 2] / 32768.0f : 0.0f;
      out[frame * 2 + 1] = enabled ? samples_[position_ * 2 + 1] / 32768.0f : 0.0f;
      ++position_;
    }
    return true;
  }
 private:
  std::array<int16_t, 960> samples_{};
  size_t position_ = 480;
  uint64_t revision_ = UINT64_MAX;
};
}
#endif
