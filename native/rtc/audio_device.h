#ifndef MICDROP_RTC_AUDIO_DEVICE_H
#define MICDROP_RTC_AUDIO_DEVICE_H
#include "api/audio/audio_device.h"
#include "api/scoped_refptr.h"
#include "common_audio/resampler/include/push_resampler.h"
#include "../platform/windows/capture.h"
#include "../platform/windows/bridge.h"
#include "playout_buffer.h"
#include "audio_mode.h"
#include "stereo.h"
#include <array>
#include <atomic>
#include <mutex>
#include <condition_variable>
#include <string>
#include <thread>

namespace micdrop {
// A native external-PCM device with no implicit input/output selection.
// Windows capture drives 10 ms blocks into WebRTC's recording transport;
// return audio is pulled by the explicitly selected render endpoint's clock.
class AudioDevice : public webrtc::AudioDeviceModule {
 public:
  AudioDevice(int source, std::string endpoint, std::string return_endpoint = "");
  ~AudioDevice() override;
  void Authorize();
  uint64_t SentFrames() const { return sent_frames_; }
  uint64_t ReceivedFrames() const { return received_frames_; }
  uint64_t StereoFrames() const { return stereo_frames_; }
  uint32_t SourceRate() const { return source_rate_; }
  uint32_t SourceChannels() const { return source_channels_; }
  bool Failed() const { return failed_ || bridge_failed_; }
  bool CaptureFailed() const { return failed_; }
  bool BridgeFailed() const { return bridge_failed_; }
  bool SetMicrophoneMuted(bool muted);
  bool MicrophoneMuted() const { return (return_gate_.load() & 1) == 0; }
  uint64_t BridgeFrames() const { return bridge_frames_; }
  uint64_t BridgeNonzeroFrames() const { return bridge_nonzero_frames_; }
  uint32_t BridgeBufferFrames() const { return bridge_buffer_; }
  uint32_t BridgeMixRate() const { return bridge_mix_rate_; }
  uint32_t BridgeMixChannels() const { return bridge_mix_channels_; }
  mdw_error BridgeError() const;

  int32_t ActiveAudioLayer(AudioLayer* layer) const override { *layer = kDummyAudio; return 0; }
  int32_t RegisterAudioCallback(webrtc::AudioTransport* callback) override { transport_ = callback; return 0; }
  int32_t Init() override { initialized_ = true; return 0; }
  int32_t Terminate() override { StopRecording(); StopPlayout(); initialized_ = false; return 0; }
  bool Initialized() const override { return initialized_; }
  int16_t PlayoutDevices() override { return 1; }
  int16_t RecordingDevices() override { return 1; }
  int32_t PlayoutDeviceName(uint16_t, char* name, char* guid) override;
  int32_t RecordingDeviceName(uint16_t, char* name, char* guid) override;
  int32_t SetPlayoutDevice(uint16_t) override { return 0; }
  int32_t SetPlayoutDevice(WindowsDeviceType) override { return 0; }
  int32_t SetRecordingDevice(uint16_t) override { return 0; }
  int32_t SetRecordingDevice(WindowsDeviceType) override { return 0; }
  int32_t PlayoutIsAvailable(bool* v) override { *v = true; return 0; }
  int32_t InitPlayout() override { return 0; }
  bool PlayoutIsInitialized() const override { return initialized_; }
  int32_t RecordingIsAvailable(bool* v) override { *v = DesktopSource(source_); return 0; }
  int32_t InitRecording() override { return 0; }
  bool RecordingIsInitialized() const override { return initialized_; }
  int32_t StartPlayout() override;
  int32_t StopPlayout() override;
  bool Playing() const override { return playing_; }
  int32_t StartRecording() override;
  int32_t StopRecording() override;
  bool Recording() const override { return recording_; }
  int32_t InitSpeaker() override { return 0; }
  bool SpeakerIsInitialized() const override { return initialized_; }
  int32_t InitMicrophone() override { return 0; }
  bool MicrophoneIsInitialized() const override { return initialized_; }
  int32_t SpeakerVolumeIsAvailable(bool* v) override { *v = false; return 0; }
  int32_t SetSpeakerVolume(uint32_t) override { return -1; }
  int32_t SpeakerVolume(uint32_t* v) const override { *v = 0; return -1; }
  int32_t MaxSpeakerVolume(uint32_t* v) const override { *v = 0; return -1; }
  int32_t MinSpeakerVolume(uint32_t* v) const override { *v = 0; return -1; }
  int32_t MicrophoneVolumeIsAvailable(bool* v) override { *v = false; return 0; }
  int32_t SetMicrophoneVolume(uint32_t) override { return -1; }
  int32_t MicrophoneVolume(uint32_t* v) const override { *v = 0; return -1; }
  int32_t MaxMicrophoneVolume(uint32_t* v) const override { *v = 0; return -1; }
  int32_t MinMicrophoneVolume(uint32_t* v) const override { *v = 0; return -1; }
  int32_t SpeakerMuteIsAvailable(bool* v) override { *v = false; return 0; }
  int32_t SetSpeakerMute(bool) override { return -1; }
  int32_t SpeakerMute(bool* v) const override { *v = false; return -1; }
  int32_t MicrophoneMuteIsAvailable(bool* v) override { *v = false; return 0; }
  int32_t SetMicrophoneMute(bool) override { return -1; }
  int32_t MicrophoneMute(bool* v) const override { *v = false; return -1; }
  int32_t StereoPlayoutIsAvailable(bool* v) const override { *v = true; return 0; }
  int32_t SetStereoPlayout(bool enabled) override { return enabled ? 0 : -1; }
  int32_t StereoPlayout(bool* v) const override { *v = true; return 0; }
  int32_t StereoRecordingIsAvailable(bool* v) const override { *v = true; return 0; }
  int32_t SetStereoRecording(bool enabled) override { return enabled ? 0 : -1; }
  int32_t StereoRecording(bool* v) const override { *v = true; return 0; }
  int32_t PlayoutDelay(uint16_t* v) const override { *v = 0; return 0; }
  bool BuiltInAECIsAvailable() const override { return false; }
  bool BuiltInAGCIsAvailable() const override { return false; }
  bool BuiltInNSIsAvailable() const override { return false; }
  int32_t EnableBuiltInAEC(bool enable) override { return enable ? -1 : 0; }
  int32_t EnableBuiltInAGC(bool enable) override { return enable ? -1 : 0; }
  int32_t EnableBuiltInNS(bool enable) override { return enable ? -1 : 0; }

 private:
  void MaybeStart();
  void MaybeStartPlayout();
  void Produce();
  void Send(const int16_t* samples);
  void FailBridge(int32_t hresult, const char* operation);
  static int Format(void* context, const mdw_report* format);
  static int Packet(void* context, const float* samples, uint32_t frames, uint32_t flags);
  static int Pull(void* context, float* stereo, uint32_t frames);
  static uint64_t Gate(void* context);
  static void Applied(void* context, uint64_t revision);
  static void BridgeStatus(void* context, const mdw_bridge_report* report);
  const int source_;
  const std::string endpoint_;
  const std::string return_endpoint_;
  std::atomic<webrtc::AudioTransport*> transport_{nullptr};
  std::atomic<bool> initialized_{false}, authorized_{false}, recording_{false}, playing_{false}, failed_{false};
  std::atomic<bool> bridge_failed_{false};
  std::atomic<uint64_t> sent_frames_{0}, received_frames_{0}, stereo_frames_{0};
  std::atomic<uint32_t> source_rate_{0}, source_channels_{0};
  std::mutex producer_mutex_;
  std::thread producer_, playout_;
  mdw_cancel* cancel_ = nullptr;
  std::mutex playout_mutex_, return_wait_mutex_;
  mutable std::mutex return_error_mutex_;
  mdw_error return_error_{};
  std::condition_variable return_applied_;
  mdw_cancel* return_cancel_ = nullptr;
  std::atomic<uint64_t> return_gate_{0}, applied_gate_{UINT64_MAX}, bridge_frames_{0};
  std::atomic<uint64_t> bridge_nonzero_frames_{0};
  std::atomic<uint32_t> bridge_buffer_{0}, bridge_mix_rate_{0}, bridge_mix_channels_{0};
  PlayoutBuffer playout_buffer_;
  StereoMatrix matrix_;
  std::unique_ptr<webrtc::PushResampler<int16_t>> resampler_;
  std::array<int16_t, 7680> input_{}; // <= 384 kHz, stereo, 10 ms
  std::array<int16_t, 960> output_{};
  size_t filled_ = 0, input_frames_ = 0;
};
}  // namespace micdrop
#endif
