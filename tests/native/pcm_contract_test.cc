#include "pcm.h"
#include "capture.h"
#include <array>
#include <cstdio>
#include <limits>

namespace {
int failures = 0;
void expect(bool ok, const char* message) {
  if (!ok) { std::fprintf(stderr, "FAIL: %s\n", message); ++failures; }
}
bool near(float a, float b) { return std::abs(a - b) < 0.00001f; }
}

int main() {
  using namespace micdrop::pcm;
  // Mono minima, -0.5, zero, +0.5, maxima in each little-endian container.
  const std::array<uint8_t, 10> pcm16{0,0x80, 0,0xc0, 0,0, 0,0x40, 0xff,0x7f};
  const std::array<uint8_t, 15> pcm24{0,0,0x80, 0,0,0xc0, 0,0,0, 0,0,0x40, 0xff,0xff,0x7f};
  const std::array<uint8_t, 20> pcm32{0,0,0,0x80, 0,0,0,0xc0, 0,0,0,0, 0,0,0,0x40, 0xff,0xff,0xff,0x7f};
  float out[6]{99,99,99,99,99,99};
  for (const auto bits : {16u, 24u, 32u}) {
    const auto* bytes = bits == 16 ? pcm16.data() : bits == 24 ? pcm24.data() : pcm32.data();
    const Format f{48000, 1, bits, bits, bits / 8, false};
    expect(decode(f, bytes, 5 * (bits / 8), 5, false, out, 6), "decode PCM container");
    expect(near(out[0], -1) && near(out[1], -0.5f) && out[2] == 0 && near(out[3], 0.5f), "signed PCM scaling");
    expect(out[4] > 0.9999f && out[4] <= 1 && out[5] == 99, "PCM maximum and guard");
  }
  const Format valid24{44100, 1, 32, 24, 4, false};
  const uint8_t padded[]{0xff,0,0,0x40, 0x7f,0,0,0xc0};
  expect(decode(valid24, padded, sizeof(padded), 2, false, out, 6) && out[0] == 0.5f && out[1] == -0.5f,
      "24 valid bits left aligned in 32-bit container; ignore padding");

  const Format stereo{48000, 2, 16, 16, 4, false};
  const uint8_t interleaved[]{0,0x40, 0,0xc0, 0,0x20, 0,0xe0};
  expect(decode(stereo, interleaved, sizeof(interleaved), 2, false, out, 6) &&
      out[0] == 0.5f && out[1] == -0.5f && out[2] == 0.25f && out[3] == -0.25f, "stereo order preserved");
  std::fill_n(out, 6, 99.0f);
  expect(!decode(stereo, interleaved, sizeof(interleaved), 2, false, out, 3) && out[0] == 99,
      "reject short output without writing");
  expect(!decode(stereo, interleaved, 7, 2, false, out, 6) && out[0] == 99, "reject truncated input");
  expect(!decode(stereo, nullptr, 0, 2, false, out, 6), "null non-silent input rejected");
  expect(decode(stereo, nullptr, 0, 2, true, out, 6) && out[0] == 0 && out[3] == 0 && out[4] == 99,
      "silent flag accepts null input and zeroes exactly the packet");

  const Format floating{96000, 1, 32, 32, 4, true};
  const uint8_t floats[]{0,0,0,0x3f, 0,0,0x80,0xbf, 0,0,0xc0,0x3f};
  expect(decode(floating, floats, sizeof(floats), 3, false, out, 6) && out[0] == 0.5f && out[1] == -1 && out[2] == 1.5f,
      "float data retains above-full-scale samples for diagnostics");
  for (const Format bad : {Format{48000,0,16,16,0,false}, Format{48000,2,16,16,2,false},
      Format{48000,1,32,33,4,false}, Format{48000,1,32,24,4,true}, Format{48000,1,8,8,1,false}}) {
    expect(!supported(bad), "unsupported format rejected");
  }
  expect(to_pcm16(-2) == -32768 && to_pcm16(2) == 32767 && to_pcm16(0.5f) == 16384 &&
      to_pcm16(-0.5f) == -16384 && to_pcm16(std::numeric_limits<float>::infinity()) == 0 &&
      to_pcm16(std::numeric_limits<float>::quiet_NaN()) == 0, "PCM16 saturation and nonfinite sanitization");

  Positions times;
  times.add(100, 10000, 10, false);
  times.add(110, 12000, 10, false);
  times.add(140, 18000, 10, false);
  expect(times.valid == 3 && times.gaps == 20 && times.regressions == 0, "packet gap counted in frames");
  times.add(999, 999, 10, true);
  times.add(190, 20000, 10, false);
  expect(times.valid == 4 && times.gaps == 20, "invalid timestamp breaks continuity comparisons");
  times.add(180, 19000, 10, false);
  expect(times.regressions == 1 && times.gaps == 20 && times.first_frame == 100 && times.last_frame == 180 &&
      times.first_qpc == 10000 && times.last_qpc == 19000, "regressions do not underflow gap counter");
  return failures ? 1 : 0;
}
