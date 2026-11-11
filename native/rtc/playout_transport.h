#ifndef MICDROP_RTC_PLAYOUT_TRANSPORT_H
#define MICDROP_RTC_PLAYOUT_TRANSPORT_H
#include <algorithm>
#include <cstddef>
#include <cstdint>

namespace micdrop {
// AudioTransport requests frames but returns a count of interleaved int16
// samples. Its historical bytes-per-sample argument is actually bytes per
// frame. See the pinned audio/audio_transport_impl.cc, NeedMorePlayData().
template<typename Transport>
bool PullStereo10ms(Transport* transport, int16_t* samples, size_t& frames) {
  frames = 0;
  std::fill(samples, samples + 960, 0);
  if (!transport) return true;
  size_t count = 0;
  int64_t elapsed = 0, ntp = 0;
  if (transport->NeedMorePlayData(480, 4, 2, 48000, samples, count, &elapsed, &ntp) != 0 ||
      count > 960 || count % 2 != 0) return false;
  std::fill(samples + count, samples + 960, 0);
  frames = count / 2;
  return true;
}
}  // namespace micdrop
#endif
