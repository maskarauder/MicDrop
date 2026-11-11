#include "bridge_signal.h"
#include <array>
#include <cmath>
#include <cstdio>
#include <vector>

int main() {
  using namespace micdrop::bridge_signal;
  constexpr uint32_t frames = rate * 4;
  std::vector<uint8_t> whole(size_t(frames) * frame_bytes), parts(whole.size());
  bool ok = fill(whole.data(), whole.size(), 0, frames);
  // Awkward packet boundaries, including one across a tone/silence boundary.
  uint32_t position = 0;
  while (position < frames) {
    const auto count = std::min<uint32_t>(997, frames - position);
    ok = ok && fill(parts.data() + position * frame_bytes, count * frame_bytes, position, count);
    position += count;
  }
  ok = ok && parts == whole;
  double energy = 0;
  for (uint32_t i = 0; i < frames; ++i) {
    float left = 0, right = 0;
    std::memcpy(&left, whole.data() + i * frame_bytes, sizeof(left));
    std::memcpy(&right, whole.data() + i * frame_bytes + sizeof(left), sizeof(right));
    ok = ok && std::isfinite(left) && left == right && std::abs(left) <= 0.050001f;
    if (i / rate % 2 == 1) ok = ok && left == 0;
    energy += double(left) * left;
  }
  ok = ok && energy > 1;
  std::array<uint8_t, 32> guard{};
  guard.fill(0xab);
  const auto original = guard;
  ok = ok && !fill(guard.data(), 7, 0, 1) && guard == original;
  ok = ok && !fill(guard.data(), guard.size(), UINT64_MAX, 1) && guard == original;
  ok = ok && !fill(nullptr, guard.size(), 0, 1);
  ok = ok && fill(guard.data() + 1, 8, 123, 1) && guard[0] == 0xab && guard[9] == 0xab;
  if (!ok) std::fprintf(stderr, "Bridge signal bounds, silence, stereo or packet continuity contract failed\n");
  return ok ? 0 : 1;
}
