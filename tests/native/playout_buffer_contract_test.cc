#include "../../native/rtc/playout_buffer.h"
#include <array>
#include <cmath>
#include <cstdio>
#include <limits>

int main() {
  micdrop::PlayoutBuffer buffer;
  int block = 0;
  auto pull = [&](int16_t* samples) {
    ++block;
    for (size_t i = 0; i < 480; ++i) { samples[i * 2] = int16_t(block * 100); samples[i * 2 + 1] = int16_t(-block * 100); }
    return true;
  };
  std::array<float, 9602> out{};
  out.front() = 42; out.back() = 43;
  bool ok = buffer.Fill(out.data() + 1, 100, 1, pull) && block == 1;
  ok = ok && out[1] == 100 / 32768.0f && out[2] == -100 / 32768.0f;
  ok = ok && buffer.Fill(out.data() + 1, 400, 1, pull) && block == 2;
  ok = ok && out[1] == 100 / 32768.0f && out[761] == 200 / 32768.0f;
  // Muting discards the leftover block but still consumes the decoder clock.
  ok = ok && buffer.Fill(out.data() + 1, 4800, 2, pull) && block == 12;
  for (size_t i = 1; i < 9601; ++i) ok = ok && out[i] == 0;
  // A new revision must not expose the pre-mute sample, even for a short read.
  ok = ok && buffer.Fill(out.data() + 1, 1, 5, pull) && block == 13 && out[1] == 1300 / 32768.0f;
  const auto before = block;
  ok = ok && !buffer.Fill(nullptr, 1, 5, pull) && !buffer.Fill(out.data() + 1, 0, 5, pull) &&
      !buffer.Fill(out.data() + 1, 4801, 5, pull) && block == before;
  ok = ok && out.front() == 42 && out.back() == 43;
  auto full_scale = [](int16_t* samples) {
    for (size_t i = 0; i < 480; ++i) { samples[i * 2] = INT16_MIN; samples[i * 2 + 1] = INT16_MAX; }
    return true;
  };
  ok = ok && buffer.Fill(out.data() + 1, 480, 7, full_scale);
  for (size_t i = 1; i <= 960; ++i) ok = ok && std::isfinite(out[i]) && out[i] >= -1 && out[i] < 1;
  if (!ok) std::puts("Bounded playout/mute continuity contract failed");
  return ok ? 0 : 1;
}
