#ifndef MICDROP_WINDOWS_PCM_H
#define MICDROP_WINDOWS_PCM_H

#include <algorithm>
#include <cmath>
#include <cstddef>
#include <cstdint>
#include <cstring>

namespace micdrop::pcm {
struct Format {
  uint32_t rate, channels, bits, valid_bits, block_align;
  bool floating;
};

inline bool supported(const Format& f) {
  return f.rate >= 8000 && f.rate <= 384000 && f.channels >= 1 && f.channels <= 32 &&
      f.block_align == f.channels * (f.bits / 8) &&
      ((f.floating && f.bits == 32 && f.valid_bits == 32) ||
       (!f.floating && (f.bits == 16 || f.bits == 24 || f.bits == 32) &&
        f.valid_bits > 0 && f.valid_bits <= f.bits));
}

// Checked before touching output; packed PCM is little endian, signed, with
// valid bits left aligned in its container. Avoid unaligned loads and signed
// shift/overflow. A SILENT packet may have a null data pointer.
inline bool decode(const Format& f, const uint8_t* source, size_t source_bytes,
                   uint32_t frames, bool silent, float* out, size_t capacity) {
  if (!supported(f) || !out || frames > capacity / f.channels ||
      (!silent && (!source || frames > source_bytes / f.block_align))) return false;
  const size_t count = static_cast<size_t>(frames) * f.channels;
  if (silent) { std::fill_n(out, count, 0.0f); return true; }
  const uint32_t bytes = f.bits / 8;
  for (size_t i = 0; i < count; ++i) {
    uint32_t raw = 0;
    for (uint32_t b = 0; b < bytes; ++b) raw |= uint32_t(source[i * bytes + b]) << (8 * b);
    if (f.floating) {
      std::memcpy(out + i, &raw, sizeof(raw));
    } else {
      raw >>= f.bits - f.valid_bits;
      const int64_t signed_value = (raw & (uint32_t{1} << (f.valid_bits - 1)))
          ? int64_t(raw) - (int64_t{1} << f.valid_bits) : int64_t(raw);
      out[i] = static_cast<float>(double(signed_value) / double(uint64_t{1} << (f.valid_bits - 1)));
    }
  }
  return true;
}

inline int16_t to_pcm16(float sample) {
  if (!std::isfinite(sample)) return 0;
  const auto scaled = std::lround(std::clamp(sample, -1.0f, 1.0f) * 32768.0f);
  return static_cast<int16_t>(std::clamp(scaled, -32768L, 32767L));
}

struct Positions {
  bool previous_valid = false;
  uint64_t previous_end = 0, previous_qpc = 0;
  uint64_t valid = 0, gaps = 0, regressions = 0;
  uint64_t first_frame = 0, last_frame = 0, first_qpc = 0, last_qpc = 0;
  void add(uint64_t frame, uint64_t qpc, uint32_t frames, bool timestamp_error) {
    if (timestamp_error) { previous_valid = false; return; }
    if (valid == 0) { first_frame = frame; first_qpc = qpc; }
    if (previous_valid) {
      if (frame < previous_end || qpc < previous_qpc) ++regressions;
      else gaps += frame - previous_end;
    }
    ++valid;
    last_frame = frame; last_qpc = qpc;
    previous_end = frame + frames; previous_qpc = qpc; previous_valid = true;
  }
};
}  // namespace micdrop::pcm
#endif
