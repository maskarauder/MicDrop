#include "../../native/rtc/stereo.h"
#include <cmath>
#include <cstdio>
#include <limits>
int main() {
  micdrop::StereoMatrix matrix;
  float frame[8]{0.2f, -0.3f};
  if (!matrix.Configure(8, 0x63f)) return 1;
  auto stereo = matrix.Mix(frame);
  if (stereo[0] != frame[0] || stereo[1] != frame[1]) return 1;
  frame[0] = frame[1] = 0; frame[2] = 1;
  stereo = matrix.Mix(frame);
  if (std::abs(stereo[0] - 0.70710678f) > 0.00001f || stereo[0] != stereo[1]) return 1;
  frame[2] = 0; frame[3] = 1;
  stereo = matrix.Mix(frame); if (stereo[0] != 0 || stereo[1] != 0) return 1;
  if (matrix.Configure(8, 0) || matrix.Configure(2, 0x80000001)) return 1;
  if (!matrix.Configure(1, 0)) return 1;
  frame[0] = 0.4f; stereo = matrix.Mix(frame);
  if (stereo[0] != 0.4f || stereo[1] != 0.4f) return 1;
  frame[0] = std::numeric_limits<float>::quiet_NaN(); stereo = matrix.Mix(frame);
  if (stereo[0] != 0 || stereo[1] != 0) return 1;
  std::puts("Stereo mapping contracts passed");
}
