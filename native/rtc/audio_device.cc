#include "audio_device.h"
#include "playout_transport.h"
#include "../platform/windows/pcm.h"
#include <chrono>
#include <cstring>
#include <cstdio>
#include <numbers>
#ifndef _WIN32
#include <strings.h>
#endif

namespace micdrop {
namespace {
bool SameEndpointId(const char* a, const char* b) {
#ifdef _WIN32
  return _stricmp(a, b) == 0;
#else
  return strcasecmp(a, b) == 0;
#endif
}
}  // namespace
AudioDevice::AudioDevice(int source, std::string endpoint, std::string return_endpoint)
    : source_(source), endpoint_(std::move(endpoint)),
      return_endpoint_(source == 3 ? endpoint_ : std::move(return_endpoint)),
      return_gate_(source == 2 ? 1 : 0) {}
AudioDevice::~AudioDevice() { Terminate(); }
int32_t AudioDevice::PlayoutDeviceName(uint16_t index, char* name, char* guid) {
  if (index != 0 || !name) return -1;
  const char* label = CableOutput(source_) ? "MicDrop explicit microphone cable" : "MicDrop decoded-PCM test sink";
  std::memcpy(name, label, std::strlen(label) + 1); if (guid) guid[0] = '\0'; return 0;
}
int32_t AudioDevice::RecordingDeviceName(uint16_t index, char* name, char* guid) {
  if (index != 0 || !name) return -1;
  constexpr char label[] = "MicDrop external desktop PCM";
  std::memcpy(name, label, sizeof(label)); if (guid) guid[0] = '\0'; return 0;
}
void AudioDevice::Authorize() { authorized_ = true; MaybeStart(); MaybeStartPlayout(); }
int32_t AudioDevice::StartRecording() {
  recording_ = true;
  try { MaybeStart(); return 0; }
  catch (...) { recording_ = false; failed_ = true; return -1; }
}
void AudioDevice::MaybeStart() {
  std::lock_guard lock(producer_mutex_);
  if (!authorized_ || !recording_ || !DesktopSource(source_) || producer_.joinable()) return;
  cancel_ = mdw_cancel_create();
  if (!cancel_) { failed_ = true; return; }
  producer_ = std::thread([this] { Produce(); });
}
int32_t AudioDevice::StopRecording() {
  std::lock_guard lock(producer_mutex_);
  recording_ = false;
  if (cancel_) mdw_cancel_request(cancel_);
  if (producer_.joinable()) producer_.join();
  mdw_cancel_free(cancel_); cancel_ = nullptr;
  return 0;
}
void AudioDevice::Send(const int16_t* samples) {
  auto* transport = transport_.load();
  if (!recording_ || !authorized_ || !transport) return;
  uint32_t level = 0;
  // WebRTC expects bytes per frame here (16-bit * stereo), not per channel.
  transport->RecordedDataIsAvailable(samples, 480, 4, 2, 48000, 0, 0, 0, false, level);
  sent_frames_ += 480;
}
int AudioDevice::Format(void* context, const mdw_report* format) {
  auto& self = *static_cast<AudioDevice*>(context);
  // Reject the return cable as the resolved default capture too. Otherwise the
  // cable can feed its own microphone signal back through desktop playback.
  if (LoopbackCapture(self.source_) && !self.return_endpoint_.empty() &&
      SameEndpointId(format->device.id, self.return_endpoint_.c_str())) return 1;
  if (format->sample_rate % 100 || !self.matrix_.Configure(format->channels, format->channel_mask)) return 1;
  self.source_rate_ = format->sample_rate; self.source_channels_ = format->channels;
  self.input_frames_ = format->sample_rate / 100; self.filled_ = 0;
  if (self.input_frames_ == 0 || self.input_frames_ > self.input_.size() / 2) return 1;
  self.input_.fill(0); self.output_.fill(0);
  self.resampler_ = std::make_unique<webrtc::PushResampler<int16_t>>(self.input_frames_, 480, 2);
  // Warm the conversion path before device Start, so first-packet setup cannot allocate.
  self.resampler_->Resample(webrtc::InterleavedView<const int16_t>(self.input_.data(), self.input_frames_, 2),
      webrtc::InterleavedView<int16_t>(self.output_.data(), 480, 2));
  return 0;
}
int AudioDevice::Packet(void* context, const float* samples, uint32_t frames, uint32_t flags) {
  auto& self = *static_cast<AudioDevice*>(context);
  if ((flags & 1) != 0) self.filled_ = 0; // AUDCLNT_BUFFERFLAGS_DATA_DISCONTINUITY
  const uint32_t channels = self.source_channels_;
  for (uint32_t frame = 0; frame < frames; ++frame) {
    const auto mixed = self.matrix_.Mix(samples + static_cast<size_t>(frame) * channels);
    self.input_[self.filled_ * 2] = pcm::to_pcm16(mixed[0]);
    self.input_[self.filled_ * 2 + 1] = pcm::to_pcm16(mixed[1]);
    if (++self.filled_ == self.input_frames_) {
      self.resampler_->Resample(webrtc::InterleavedView<const int16_t>(self.input_.data(), self.input_frames_, 2),
          webrtc::InterleavedView<int16_t>(self.output_.data(), 480, 2));
      self.Send(self.output_.data()); self.filled_ = 0;
    }
  }
  return 0;
}
void AudioDevice::Produce() {
  try {
    if (LoopbackCapture(source_)) {
      mdw_error error{};
      const int result = mdw_capture_live(endpoint_.c_str(), cancel_, this, Format, Packet, &error);
      if (result == 1) failed_ = true;
      return;
    }
    source_rate_ = 48000; source_channels_ = 2;
    std::array<int16_t, 960> samples{};
    uint64_t frame = 0;
    auto next = std::chrono::steady_clock::now();
    while (recording_) {
      for (size_t i = 0; i < 480; ++i, ++frame) {
        samples[i*2] = pcm::to_pcm16(0.05f * static_cast<float>(std::sin(2 * std::numbers::pi * 440 * double(frame) / 48000)));
        samples[i*2+1] = pcm::to_pcm16(0.05f * static_cast<float>(std::sin(2 * std::numbers::pi * 660 * double(frame) / 48000)));
      }
      Send(samples.data());
      next += std::chrono::milliseconds(10);
      if (next < std::chrono::steady_clock::now()) next = std::chrono::steady_clock::now();
      std::this_thread::sleep_until(next);
    }
  } catch (...) { failed_ = true; }
}
int32_t AudioDevice::StartPlayout() {
  if (CableOutput(source_)) {
    {
      std::lock_guard lock(playout_mutex_);
      if (playing_.exchange(true)) return 0;
    }
    try { MaybeStartPlayout(); return 0; }
    catch (...) { playing_ = false; FailBridge(-2147467259, "Start microphone playout thread"); return -1; }
  }
  std::lock_guard lock(playout_mutex_);
  if (playing_.exchange(true) || playout_.joinable()) return 0;
  try { playout_ = std::thread([this] {
    std::array<float, 960> samples{};
    auto next = std::chrono::steady_clock::now();
    while (playing_) {
      // Exercise the live bridge's exact bounded adapter in headless loopback.
      const auto gate = Gate(this);
      if (Pull(this, samples.data(), 480) != 0) { failed_ = true; break; }
      // A control change during Pull must be applied by the next iteration.
      if (MicrophoneReturn(source_) && Gate(this) == gate) Applied(this, gate);
      next += std::chrono::milliseconds(10);
      if (next < std::chrono::steady_clock::now()) next = std::chrono::steady_clock::now();
      std::this_thread::sleep_until(next);
    }
  }); } catch (...) { playing_ = false; failed_ = true; return -1; }
  return 0;
}
int32_t AudioDevice::StopPlayout() {
  std::lock_guard lock(playout_mutex_);
  playing_ = false;
  return_applied_.notify_all();
  if (return_cancel_) mdw_cancel_request(return_cancel_);
  if (playout_.joinable()) playout_.join();
  mdw_cancel_free(return_cancel_); return_cancel_ = nullptr;
  return 0;
}

void AudioDevice::MaybeStartPlayout() {
  std::lock_guard lock(playout_mutex_);
  if (!CableOutput(source_) || !authorized_ || !playing_ || playout_.joinable()) return;
  return_cancel_ = mdw_cancel_create();
  if (!return_cancel_) { FailBridge(-2147024882, "Allocate microphone cancellation event"); return; }
  try { playout_ = std::thread([this] {
    mdw_error error{};
    const int result = mdw_bridge_live(return_endpoint_.c_str(), return_cancel_, this,
        Pull, Gate, Applied, BridgeStatus, &error);
    // The native boundary supplies fixed operation labels, never endpoint text.
    if (result != 2) FailBridge(error.hresult, error.message);
    return_applied_.notify_all();
  }); } catch (...) { FailBridge(-2147467259, "Start microphone playout thread"); }
}
bool AudioDevice::SetMicrophoneMuted(bool muted) {
  if (!MicrophoneReturn(source_) || !authorized_) return false;
  const auto previous = return_gate_.load();
  const bool enabled = !muted;
  uint64_t desired = previous;
  if (((previous & 1) != 0) != enabled) {
    desired = (((previous >> 1) + 1) << 1) | (enabled ? 1 : 0);
    return_gate_ = desired;
  }
  std::unique_lock lock(return_wait_mutex_);
  const auto deadline = std::chrono::steady_clock::now() + std::chrono::seconds(5);
  // The render callback publishes atomics and never takes this control mutex.
  // Short waits also cover a notification racing with entry into wait().
  while (applied_gate_ != desired && !Failed() && playing_ && std::chrono::steady_clock::now() < deadline)
    return_applied_.wait_for(lock, std::chrono::milliseconds(20));
  if (!Failed() && (!playing_ || applied_gate_ != desired))
    FailBridge(-2147023436, "Apply microphone cable mute state");
  return !Failed() && playing_ && applied_gate_ == desired;
}
void AudioDevice::FailBridge(int32_t hresult, const char* operation) {
  {
    std::lock_guard lock(return_error_mutex_);
    // Preserve the original render error if a control timeout races with it.
    if (!bridge_failed_) {
      return_error_.hresult = hresult;
      std::snprintf(return_error_.message, sizeof(return_error_.message), "%s", operation);
      bridge_failed_ = true;
    }
  }
  return_applied_.notify_all();
}
mdw_error AudioDevice::BridgeError() const {
  std::lock_guard lock(return_error_mutex_);
  return return_error_;
}
uint64_t AudioDevice::Gate(void* context) { return static_cast<AudioDevice*>(context)->return_gate_; }
void AudioDevice::Applied(void* context, uint64_t revision) {
  auto& self = *static_cast<AudioDevice*>(context);
  self.applied_gate_ = revision;
  self.return_applied_.notify_all();
}
void AudioDevice::BridgeStatus(void* context, const mdw_bridge_report* report) {
  auto& self = *static_cast<AudioDevice*>(context);
  self.bridge_frames_ = report->frames_written; self.bridge_buffer_ = report->buffer_frames;
  self.bridge_mix_rate_ = report->mix_rate; self.bridge_mix_channels_ = report->mix_channels;
}
int AudioDevice::Pull(void* context, float* stereo, uint32_t frames) {
  auto& self = *static_cast<AudioDevice*>(context);
  const bool filled = self.playout_buffer_.Fill(stereo, frames, self.return_gate_.load(), [&](int16_t* samples) {
    size_t count = 0;
    if (!PullStereo10ms(self.transport_.load(), samples, count)) return false;
    for (size_t i = 0; i < count; ++i) {
      if (samples[i * 2] != 0 || samples[i * 2 + 1] != 0) ++self.received_frames_;
      if (std::abs(int(samples[i * 2]) - samples[i * 2 + 1]) > 100) ++self.stereo_frames_;
    }
    return true;
  });
  if (!filled) return 1;
  if (MicrophoneReturn(self.source_)) {
    uint64_t nonzero = 0;
    for (uint32_t i = 0; i < frames; ++i)
      if (stereo[i * 2] != 0 || stereo[i * 2 + 1] != 0) ++nonzero;
    self.bridge_nonzero_frames_ += nonzero;
  }
  return 0;
}
}  // namespace micdrop
