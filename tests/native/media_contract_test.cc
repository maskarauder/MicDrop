#include "capi.h"

#include <array>
#include <cmath>
#include <cstdlib>
#include <iostream>
#include <limits>

extern "C" int md_test_c_header(void);

static void check(bool condition, const char* message) {
  if (!condition) {
    std::cerr << message << '\n';
    std::exit(1);
  }
}

int main() {
  check(md_test_c_header() != 0, "C ABI version mismatch");
  md_tone_config config{48000, 2, 1000.0f, 0.05f};
  md_tone* whole = nullptr;
  md_tone* split = nullptr;
  check(md_tone_create(&config, &whole) == MD_OK, "create whole");
  check(md_tone_create(&config, &split) == MD_OK, "create split");
  std::array<float, 960> expected{};
  std::array<float, 962> actual{};
  actual.front() = actual.back() = 123.0f;

  check(md_tone_render(split, actual.data() + 1, 959, 480) == MD_INVALID_ARGUMENT,
        "reject insufficient capacity");
  for (size_t i = 1; i < actual.size() - 1; ++i) check(actual[i] == 0, "failed render modified output");
  check(md_tone_render(split, nullptr, 0, 0) == MD_OK, "zero-frame no-op");
  check(md_tone_render(whole, expected.data(), expected.size(), 480) == MD_OK, "whole block");
  check(md_tone_render(split, actual.data() + 1, 320, 160) == MD_OK, "first block");
  check(md_tone_render(split, actual.data() + 321, 640, 320) == MD_OK, "second block");
  check(actual.front() == 123.0f && actual.back() == 123.0f, "buffer boundary overwrite");
  for (size_t i = 0; i < expected.size(); ++i) {
    check(expected[i] == actual[i + 1], "phase continuity after rejected and split renders");
    check(std::isfinite(expected[i]) && std::abs(expected[i]) <= 0.050001f, "sample bounds");
    if (i % 2 == 0) check(expected[i] == expected[i + 1], "stereo channel layout");
  }
  check(std::abs(expected[24] - 0.05f) < 0.000001f, "1 kHz quarter-cycle at 48 kHz");
  md_tone_destroy(whole);
  md_tone_destroy(split);
  md_tone_destroy(nullptr);

  md_tone* invalid = nullptr;
  config.frequency_hz = std::numeric_limits<float>::quiet_NaN();
  check(md_tone_create(&config, &invalid) == MD_INVALID_ARGUMENT && invalid == nullptr, "reject NaN");
  config.frequency_hz = 24000.0f;
  check(md_tone_create(&config, &invalid) == MD_INVALID_ARGUMENT, "reject Nyquist frequency");
  config.frequency_hz = 440.0f;
  config.channels = 3;
  check(md_tone_create(&config, &invalid) == MD_INVALID_ARGUMENT, "reject unsupported channels");
  check(md_tone_create(nullptr, &invalid) == MD_INVALID_ARGUMENT, "reject null config");
  check(md_tone_create(&config, nullptr) == MD_INVALID_ARGUMENT, "reject null result");
  std::cout << "Native C ABI and tone contracts passed.\n";
}
