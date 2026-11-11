#include "../../native/rtc/playout_transport.h"
#include "../../native/rtc/playout_buffer.h"
#include <array>
#include <cstdio>

struct Transport {
  size_t count = 960;
  int result = 0, calls = 0;
  bool valid = true;
  int32_t NeedMorePlayData(size_t frames, size_t bytes, size_t channels, uint32_t rate,
      void* out, size_t& returned, int64_t*, int64_t*) {
    ++calls;
    valid = valid && frames == 480 && bytes == 4 && channels == 2 && rate == 48000;
    auto* samples = static_cast<int16_t*>(out);
    for (size_t i = 0; i < 960; ++i) samples[i] = i % 2 ? -2000 : 1000;
    returned = count;
    return result;
  }
};

int main() {
  Transport transport;
  std::array<int16_t, 962> samples{};
  samples.front() = 42; samples.back() = 43;
  size_t frames = 123;
  bool ok = micdrop::PullStereo10ms(&transport, samples.data() + 1, frames) && frames == 480;
  ok = ok && samples[959] == 1000 && samples[960] == -2000 && transport.valid;
  // A short result is a sample count, not a frame count. Its tail is silent.
  transport.count = 200;
  ok = ok && micdrop::PullStereo10ms(&transport, samples.data() + 1, frames) && frames == 100;
  ok = ok && samples[199] == 1000 && samples[200] == -2000;
  for (size_t i = 201; i <= 960; ++i) ok = ok && samples[i] == 0;
  for (const auto count : {size_t{1}, size_t{959}, size_t{961}, size_t{1920}}) {
    transport.count = count;
    ok = ok && !micdrop::PullStereo10ms(&transport, samples.data() + 1, frames) && frames == 0;
  }
  transport.count = 960; transport.result = -1;
  ok = ok && !micdrop::PullStereo10ms(&transport, samples.data() + 1, frames);
  transport.result = 0; transport.count = 0;
  ok = ok && micdrop::PullStereo10ms(&transport, samples.data() + 1, frames) && frames == 0;
  for (size_t i = 1; i <= 960; ++i) ok = ok && samples[i] == 0;
  ok = ok && micdrop::PullStereo10ms(static_cast<Transport*>(nullptr), samples.data() + 1, frames) && frames == 0;
  ok = ok && samples.front() == 42 && samples.back() == 43;

  // A 1056-frame cable prefill crosses three 10ms decoder blocks. Exercise the
  // real sample/frame adapter through the same bounded buffer as live playout.
  transport.count = 960; transport.calls = 0;
  micdrop::PlayoutBuffer buffer;
  std::array<float, 2112> out{};
  auto pull = [&](int16_t* block) { return micdrop::PullStereo10ms(&transport, block, frames); };
  ok = ok && buffer.Fill(out.data(), 1056, 1, pull) && transport.calls == 3 && transport.valid;
  for (size_t i = 0; i < out.size(); ++i)
    ok = ok && out[i] == (i % 2 ? -2000 : 1000) / 32768.0f;
  ok = ok && buffer.Fill(out.data(), 1056, 2, pull) && transport.calls == 6;
  for (const auto sample : out) ok = ok && sample == 0;
  if (!ok) std::puts("WebRTC interleaved sample/frame contract failed");
  return ok ? 0 : 1;
}
