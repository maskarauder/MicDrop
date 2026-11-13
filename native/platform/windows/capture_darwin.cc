// SPDX-License-Identifier: MPL-2.0
//go:build darwin && arm64

#include "capture.h"
#include "bridge.h"
#include "bridge_signal.h"
#include "pcm.h"

#include <AudioToolbox/AudioToolbox.h>
#include <CoreAudio/AudioHardware.h>
#include <CoreAudio/AudioHardwareTapping.h>
#include <CoreAudio/CoreAudio.h>
#include <CoreFoundation/CoreFoundation.h>

#include <algorithm>
#include <array>
#include <atomic>
#include <chrono>
#include <cmath>
#include <condition_variable>
#include <cstdint>
#include <cstdio>
#include <cstring>
#include <memory>
#include <mutex>
#include <new>
#include <string>
#include <vector>

extern "C" {
OSStatus micdrop_macos_create_tap_aggregate(
    const char* device_uid_utf8,
    AudioObjectID* out_tap,
    AudioObjectID* out_aggregate);
void micdrop_macos_destroy_tap_aggregate(AudioObjectID tap_id, AudioObjectID aggregate_id);
}

namespace {

constexpr int32_t kErrInvalidArg = -2147024809;   // E_INVALIDARG
constexpr int32_t kErrOutOfMemory = -2147024882;  // E_OUTOFMEMORY
constexpr int32_t kErrFail = -2147467259;         // E_FAIL
constexpr int32_t kErrNotFound = -2147023728;     // ERROR_NOT_FOUND
constexpr int32_t kErrTimeout = -2147023436;      // ERROR_TIMEOUT

constexpr size_t kMaxRecordingBytes = 64u * 1024u * 1024u;
constexpr uint32_t kMaxPullStepFrames = 960;
constexpr uint32_t kMaxSliceFrames = 4096;

struct Failure {
  int32_t code;
  const char* operation;
};

[[noreturn]] void fail_throw(int32_t code, const char* operation) {
  throw Failure{code, operation};
}

void check_os(OSStatus status, const char* operation) {
  if (status != noErr) fail_throw(static_cast<int32_t>(status), operation);
}

void require_arg(bool ok, const char* operation) {
  if (!ok) fail_throw(kErrInvalidArg, operation);
}

void require_state(bool ok, const char* operation, int32_t code = kErrFail) {
  if (!ok) fail_throw(code, operation);
}

int fail_out(mdw_error* error, int32_t code, const char* message) {
  if (error) {
    error->hresult = code;
    std::snprintf(error->message, sizeof(error->message), "%s", message);
  }
  return 1;
}

bool valid_utf8(const char* text, size_t max_bytes_with_nul) {
  if (!text) return false;
  const auto* bytes = reinterpret_cast<const uint8_t*>(text);
  size_t i = 0;
  while (i < max_bytes_with_nul && bytes[i] != 0) {
    const uint8_t b0 = bytes[i];
    if (b0 < 0x80) {
      ++i;
    } else if ((b0 & 0xE0) == 0xC0) {
      if (b0 < 0xC2 || i + 1 >= max_bytes_with_nul) return false;
      if ((bytes[i + 1] & 0xC0) != 0x80) return false;
      i += 2;
    } else if ((b0 & 0xF0) == 0xE0) {
      if (i + 2 >= max_bytes_with_nul) return false;
      const uint8_t b1 = bytes[i + 1], b2 = bytes[i + 2];
      if ((b1 & 0xC0) != 0x80 || (b2 & 0xC0) != 0x80) return false;
      if ((b0 == 0xE0 && b1 < 0xA0) || (b0 == 0xED && b1 >= 0xA0)) return false;
      i += 3;
    } else if ((b0 & 0xF8) == 0xF0) {
      if (b0 > 0xF4 || i + 3 >= max_bytes_with_nul) return false;
      const uint8_t b1 = bytes[i + 1], b2 = bytes[i + 2], b3 = bytes[i + 3];
      if ((b1 & 0xC0) != 0x80 || (b2 & 0xC0) != 0x80 || (b3 & 0xC0) != 0x80) return false;
      if ((b0 == 0xF0 && b1 < 0x90) || (b0 == 0xF4 && b1 >= 0x90)) return false;
      i += 4;
    } else {
      return false;
    }
  }
  return i < max_bytes_with_nul && bytes[i] == 0;
}

uint64_t monotonic_100ns() {
  const auto now = std::chrono::steady_clock::now().time_since_epoch();
  return static_cast<uint64_t>(
      std::chrono::duration_cast<std::chrono::nanoseconds>(now).count() / 100);
}

uint32_t speaker_mask_for_channels(uint32_t channels) {
  switch (channels) {
    case 1:
      return 4u;
    case 2:
      return 3u;
    case 4:
      return 0x33u;
    case 6:
      return 0x3Fu;
    case 8:
      return 0x63Fu;
    default:
      return 0u;
  }
}

std::string cfstring_to_utf8(CFStringRef str, size_t max_bytes_with_nul, const char* label) {
  require_state(str != nullptr, label, kErrInvalidArg);
  const CFIndex length = CFStringGetLength(str);
  const CFIndex max_size = CFStringGetMaximumSizeForEncoding(length, kCFStringEncodingUTF8) + 1;
  std::vector<char> buf(static_cast<size_t>(std::max<CFIndex>(max_size, 16)), 0);
  require_state(
      CFStringGetCString(str, buf.data(), static_cast<CFIndex>(buf.size()), kCFStringEncodingUTF8),
      label, kErrInvalidArg);
  require_state(valid_utf8(buf.data(), max_bytes_with_nul), label, kErrInvalidArg);
  return std::string(buf.data());
}

std::string read_device_string(AudioObjectID device, AudioObjectPropertySelector selector, size_t cap, const char* label) {
  CFStringRef raw = nullptr;
  UInt32 size = sizeof(raw);
  AudioObjectPropertyAddress addr{
      selector, kAudioObjectPropertyScopeGlobal, kAudioObjectPropertyElementMain};
  check_os(AudioObjectGetPropertyData(device, &addr, 0, nullptr, &size, &raw), label);
  if (!raw) fail_throw(kErrFail, label);
  struct ReleaseCF {
    CFStringRef ref;
    ~ReleaseCF() {
      if (ref) CFRelease(ref);
    }
  } guard{raw};
  return cfstring_to_utf8(raw, cap, label);
}

uint32_t count_device_channels(AudioObjectID device, AudioObjectPropertyScope scope) {
  AudioObjectPropertyAddress addr{
      kAudioDevicePropertyStreamConfiguration, scope, kAudioObjectPropertyElementMain};
  if (!AudioObjectHasProperty(device, &addr)) return 0;
  UInt32 size = 0;
  if (AudioObjectGetPropertyDataSize(device, &addr, 0, nullptr, &size) != noErr || size == 0) {
    return 0;
  }
  std::vector<uint8_t> storage(size);
  auto* list = reinterpret_cast<AudioBufferList*>(storage.data());
  if (AudioObjectGetPropertyData(device, &addr, 0, nullptr, &size, list) != noErr) return 0;
  uint32_t channels = 0;
  for (UInt32 i = 0; i < list->mNumberBuffers; ++i) {
    channels += list->mBuffers[i].mNumberChannels;
  }
  return channels;
}

bool device_is_alive(AudioObjectID device) {
  UInt32 alive = 0;
  UInt32 size = sizeof(alive);
  AudioObjectPropertyAddress addr{
      kAudioDevicePropertyDeviceIsAlive,
      kAudioObjectPropertyScopeGlobal,
      kAudioObjectPropertyElementMain};
  if (!AudioObjectHasProperty(device, &addr)) return true;
  if (AudioObjectGetPropertyData(device, &addr, 0, nullptr, &size, &alive) != noErr) return false;
  return alive != 0;
}

AudioDeviceID query_default_device(bool output) {
  AudioDeviceID id = kAudioObjectUnknown;
  UInt32 size = sizeof(id);
  AudioObjectPropertyAddress addr{
      output ? kAudioHardwarePropertyDefaultOutputDevice
             : kAudioHardwarePropertyDefaultInputDevice,
      kAudioObjectPropertyScopeGlobal,
      kAudioObjectPropertyElementMain};
  if (AudioObjectGetPropertyData(kAudioObjectSystemObject, &addr, 0, nullptr, &size, &id) != noErr) {
    return kAudioObjectUnknown;
  }
  return id;
}

std::vector<AudioDeviceID> all_hal_devices() {
  AudioObjectPropertyAddress addr{
      kAudioHardwarePropertyDevices,
      kAudioObjectPropertyScopeGlobal,
      kAudioObjectPropertyElementMain};
  UInt32 size = 0;
  check_os(
      AudioObjectGetPropertyDataSize(kAudioObjectSystemObject, &addr, 0, nullptr, &size),
      "Query CoreAudio device list size");
  if (size == 0) return {};
  std::vector<AudioDeviceID> ids(size / sizeof(AudioDeviceID));
  check_os(
      AudioObjectGetPropertyData(kAudioObjectSystemObject, &addr, 0, nullptr, &size, ids.data()),
      "Enumerate CoreAudio devices");
  ids.resize(size / sizeof(AudioDeviceID));
  return ids;
}

bool is_internal_tap_uid(const std::string& uid) {
  return uid.rfind("io.micdrop.tap.", 0) == 0;
}

void populate_mdw_device(AudioDeviceID dev, AudioDeviceID default_dev, mdw_device& out) {
  out = {};
  const std::string uid = read_device_string(
      dev, kAudioDevicePropertyDeviceUID, sizeof(out.id), "Read CoreAudio device UID");
  const std::string name = read_device_string(
      dev, kAudioObjectPropertyName, sizeof(out.name), "Read CoreAudio device name");
  std::memcpy(out.id, uid.c_str(), uid.size() + 1);
  std::memcpy(out.name, name.c_str(), name.size() + 1);
  out.default_multimedia = (default_dev != kAudioObjectUnknown && dev == default_dev) ? 1 : 0;
}

std::vector<mdw_device> list_directional_devices(bool output) {
  const auto ids = all_hal_devices();
  const AudioDeviceID default_dev = query_default_device(output);
  const AudioObjectPropertyScope scope =
      output ? kAudioObjectPropertyScopeOutput : kAudioObjectPropertyScopeInput;
  std::vector<mdw_device> out;
  for (AudioDeviceID dev : ids) {
    if (!device_is_alive(dev)) continue;
    if (count_device_channels(dev, scope) == 0) continue;
    mdw_device item{};
    try {
      populate_mdw_device(dev, default_dev, item);
    } catch (...) {
      continue;
    }
    if (is_internal_tap_uid(item.id)) continue;
    out.push_back(item);
  }
  return out;
}

struct ResolvedDevice {
  AudioDeviceID id = kAudioObjectUnknown;
  mdw_device info{};
};

ResolvedDevice resolve_output_device(
    const char* requested_uid,
    bool allow_default,
    const char* missing_label = "Selected output endpoint was not found") {
  const AudioDeviceID default_dev = query_default_device(true);
  if (!requested_uid || !*requested_uid) {
    require_arg(allow_default, "Bridge requires an explicit render endpoint ID");
    require_state(
        default_dev != kAudioObjectUnknown && device_is_alive(default_dev) &&
            count_device_channels(default_dev, kAudioObjectPropertyScopeOutput) > 0,
        "No active default output device is available", kErrNotFound);
    ResolvedDevice res{default_dev, {}};
    populate_mdw_device(default_dev, default_dev, res.info);
    return res;
  }

  require_arg(
      valid_utf8(requested_uid, sizeof(mdw_device{}.id)),
      "Invalid or oversized UTF-8 endpoint ID");
  for (AudioDeviceID dev : all_hal_devices()) {
    if (!device_is_alive(dev)) continue;
    if (count_device_channels(dev, kAudioObjectPropertyScopeOutput) == 0) continue;
    mdw_device item{};
    try {
      populate_mdw_device(dev, default_dev, item);
    } catch (...) {
      continue;
    }
    if (std::strcmp(item.id, requested_uid) == 0) {
      return ResolvedDevice{dev, item};
    }
  }
  fail_throw(kErrNotFound, missing_label);
}

OSStatus on_alive_changed(
    AudioObjectID inObjectID,
    UInt32,
    const AudioObjectPropertyAddress*,
    void* inClientData) {
  auto* invalidated = static_cast<std::atomic<bool>*>(inClientData);
  if (!device_is_alive(inObjectID)) {
    invalidated->store(true, std::memory_order_release);
  }
  return noErr;
}

struct AliveListener {
  AudioObjectID device = kAudioObjectUnknown;
  std::atomic<bool> invalidated{false};
  bool registered = false;

  explicit AliveListener(AudioObjectID dev) : device(dev) {
    AudioObjectPropertyAddress addr{
        kAudioDevicePropertyDeviceIsAlive,
        kAudioObjectPropertyScopeGlobal,
        kAudioObjectPropertyElementMain};
    if (AudioObjectHasProperty(device, &addr)) {
      if (AudioObjectAddPropertyListener(device, &addr, on_alive_changed, &invalidated) == noErr) {
        registered = true;
      }
    }
  }
  ~AliveListener() {
    if (registered) {
      AudioObjectPropertyAddress addr{
          kAudioDevicePropertyDeviceIsAlive,
          kAudioObjectPropertyScopeGlobal,
          kAudioObjectPropertyElementMain};
      AudioObjectRemovePropertyListener(device, &addr, on_alive_changed, &invalidated);
    }
  }
  AliveListener(const AliveListener&) = delete;
  AliveListener& operator=(const AliveListener&) = delete;
};

}  // namespace

struct mdw_cancel {
  std::atomic<bool> requested{false};
  std::mutex mutex;
  std::condition_variable cv;

  bool is_cancelled() const { return requested.load(std::memory_order_acquire); }

  bool wait_ms(uint32_t ms) {
    if (is_cancelled()) return true;
    std::unique_lock<std::mutex> lock(mutex);
    return cv.wait_for(lock, std::chrono::milliseconds(ms), [this] { return is_cancelled(); });
  }
};

struct mdw_devices {
  std::vector<mdw_device> items;
};

struct mdw_recording {
  std::vector<uint8_t> bytes;
};

namespace {

struct CaptureCallbackState {
  uint32_t channels = 2;
  bool non_interleaved = false;
  bool timed = false;
  bool store_pcm = false;
  void* sink_context = nullptr;
  mdw_packet_sink packet_sink = nullptr;

  std::vector<float> scratch;
  uint8_t* recording_buf = nullptr;
  size_t recording_capacity = 0;
  size_t recording_written = 0;

  mdw_report* report = nullptr;
  std::array<double, MDW_MAX_CHANNELS> sum_squares{};
  micdrop::pcm::Positions positions{};
  uint64_t next_expected_sample = 0;
  bool have_sample_time = false;

  std::atomic<uint64_t> delivered_packets{0};
  std::atomic<bool> callback_failed{false};
  const char* failure_reason = nullptr;
};

OSStatus capture_io_proc(
    AudioObjectID,
    const AudioTimeStamp*,
    const AudioBufferList* inInputData,
    const AudioTimeStamp* inInputTime,
    AudioBufferList*,
    const AudioTimeStamp*,
    void* inClientData) {
  auto* st = static_cast<CaptureCallbackState*>(inClientData);
  if (!st || st->callback_failed.load(std::memory_order_relaxed)) return noErr;
  if (!inInputData || inInputData->mNumberBuffers == 0) return noErr;

  const uint32_t channels = st->channels;
  uint32_t frames = 0;
  const float* samples = nullptr;

  if (!st->non_interleaved) {
    const AudioBuffer& buf = inInputData->mBuffers[0];
    if (!buf.mData || buf.mNumberChannels != channels) return noErr;
    frames = buf.mDataByteSize / (channels * sizeof(float));
    if (frames == 0) return noErr;
    samples = static_cast<const float*>(buf.mData);
  } else {
    if (inInputData->mNumberBuffers < channels) return noErr;
    frames = inInputData->mBuffers[0].mDataByteSize / sizeof(float);
    if (frames == 0) return noErr;
    const size_t total = static_cast<size_t>(frames) * channels;
    if (total > st->scratch.size()) {
      st->failure_reason = "CoreAudio tap slice exceeded preallocated buffer";
      st->callback_failed.store(true, std::memory_order_release);
      return noErr;
    }
    for (uint32_t c = 0; c < channels; ++c) {
      const auto* ch_ptr = static_cast<const float*>(inInputData->mBuffers[c].mData);
      if (!ch_ptr) return noErr;
      for (uint32_t f = 0; f < frames; ++f) {
        st->scratch[static_cast<size_t>(f) * channels + c] = ch_ptr[f];
      }
    }
    samples = st->scratch.data();
  }

  uint32_t flags = 0;
  const bool ts_valid =
      inInputTime && ((inInputTime->mFlags & kAudioTimeStampSampleTimeValid) != 0);
  if (!ts_valid) {
    ++st->report->timestamp_errors;
    flags |= 4u;
  } else {
    const uint64_t sample_pos = static_cast<uint64_t>(std::max(0.0, inInputTime->mSampleTime));
    if (st->have_sample_time && sample_pos != st->next_expected_sample) {
      ++st->report->discontinuities;
      flags |= 1u;
    }
    st->have_sample_time = true;
    st->next_expected_sample = sample_pos + frames;
    st->positions.add(sample_pos, monotonic_100ns(), frames, false);
  }

  if (st->report->packets == 0 || frames < st->report->min_packet_frames) {
    st->report->min_packet_frames = frames;
  }
  if (frames > st->report->max_packet_frames) {
    st->report->max_packet_frames = frames;
  }
  ++st->report->packets;
  st->report->frames += frames;

  if (st->timed) {
    for (uint32_t f = 0; f < frames; ++f) {
      for (uint32_t c = 0; c < channels; ++c) {
        const float v = samples[static_cast<size_t>(f) * channels + c];
        if (!std::isfinite(v)) {
          ++st->report->nonfinite_samples;
          continue;
        }
        const double abs_v = std::abs(static_cast<double>(v));
        if (abs_v > 1.0) ++st->report->clipped_samples;
        if (abs_v > st->report->peak[c]) st->report->peak[c] = abs_v;
        st->sum_squares[c] += static_cast<double>(v) * static_cast<double>(v);
      }
    }
    if (st->store_pcm) {
      const size_t count = static_cast<size_t>(frames) * channels;
      const size_t bytes_needed = count * sizeof(int16_t);
      if (st->recording_written + bytes_needed > st->recording_capacity) {
        st->failure_reason = "Diagnostic PCM recording exceeded preallocated capacity";
        st->callback_failed.store(true, std::memory_order_release);
        return noErr;
      }
      uint8_t* dst = st->recording_buf + st->recording_written;
      for (size_t i = 0; i < count; ++i) {
        const uint16_t u16 = static_cast<uint16_t>(micdrop::pcm::to_pcm16(samples[i]));
        dst[i * 2] = static_cast<uint8_t>(u16 & 0xFFu);
        dst[i * 2 + 1] = static_cast<uint8_t>((u16 >> 8) & 0xFFu);
      }
      st->recording_written += bytes_needed;
    }
  }

  if (st->packet_sink) {
    if (st->packet_sink(st->sink_context, samples, frames, flags) != 0) {
      st->failure_reason = "Deliver desktop loopback packet";
      st->callback_failed.store(true, std::memory_order_release);
      return noErr;
    }
  }

  st->delivered_packets.fetch_add(1, std::memory_order_release);
  return noErr;
}

struct TapAggregateGuard {
  AudioObjectID tap_id = kAudioObjectUnknown;
  AudioObjectID aggregate_id = kAudioObjectUnknown;
  ~TapAggregateGuard() {
    if (tap_id != kAudioObjectUnknown || aggregate_id != kAudioObjectUnknown) {
      micdrop_macos_destroy_tap_aggregate(tap_id, aggregate_id);
    }
  }
};

int run_macos_capture(
    const char* endpoint_id,
    uint32_t duration_ms,
    bool timed,
    int store_pcm,
    mdw_cancel* cancel,
    mdw_report* out_report,
    mdw_recording** out_recording,
    void* sink_context,
    mdw_format_sink format_sink,
    mdw_packet_sink packet_sink,
    mdw_error* error) {
  if (error) *error = {};
  if (cancel->is_cancelled()) return 2;

  try {
    const auto target = resolve_output_device(endpoint_id, true);
    if (cancel->is_cancelled()) return 2;

    AliveListener alive(target.id);

    TapAggregateGuard tap_guard;
    const OSStatus tap_status = micdrop_macos_create_tap_aggregate(
        target.info.id, &tap_guard.tap_id, &tap_guard.aggregate_id);
    if (tap_status == kAudioHardwareUnsupportedOperationError) {
      fail_throw(kErrFail, "macOS 14.2 or newer is required for CoreAudio loopback capture");
    }
    check_os(tap_status, "Create private CoreAudio process tap aggregate");

    AudioStreamBasicDescription asbd{};
    UInt32 asbd_size = sizeof(asbd);
    AudioObjectPropertyAddress fmt_addr{
        kAudioDevicePropertyStreamFormat,
        kAudioObjectPropertyScopeInput,
        kAudioObjectPropertyElementMain};
    if (AudioObjectGetPropertyData(
            tap_guard.aggregate_id, &fmt_addr, 0, nullptr, &asbd_size, &asbd) != noErr) {
      if (__builtin_available(macOS 14.2, *)) {
        AudioObjectPropertyAddress tap_fmt_addr{
            kAudioTapPropertyFormat,
            kAudioObjectPropertyScopeGlobal,
            kAudioObjectPropertyElementMain};
        asbd_size = sizeof(asbd);
        check_os(
            AudioObjectGetPropertyData(
                tap_guard.tap_id, &tap_fmt_addr, 0, nullptr, &asbd_size, &asbd),
            "Read CoreAudio tap stream format");
      } else {
        fail_throw(kErrFail, "Read CoreAudio tap stream format");
      }
    }

    const uint32_t sample_rate = static_cast<uint32_t>(std::lround(asbd.mSampleRate));
    const uint32_t channels = asbd.mChannelsPerFrame;
    const bool is_float =
        (asbd.mFormatID == kAudioFormatLinearPCM) &&
        ((asbd.mFormatFlags & kAudioFormatFlagIsFloat) != 0) &&
        (asbd.mBitsPerChannel == 32);
    const bool non_interleaved = (asbd.mFormatFlags & kAudioFormatFlagIsNonInterleaved) != 0;
    require_state(
        is_float && sample_rate >= 8000 && sample_rate <= 384000 &&
            channels >= 1 && channels <= MDW_MAX_CHANNELS,
        "Unsupported CoreAudio tap PCM format");

    UInt32 buffer_frames = sample_rate / 100;
    UInt32 bf_size = sizeof(buffer_frames);
    AudioObjectPropertyAddress bf_addr{
        kAudioDevicePropertyBufferFrameSize,
        kAudioObjectPropertyScopeGlobal,
        kAudioObjectPropertyElementMain};
    AudioObjectGetPropertyData(
        tap_guard.aggregate_id, &bf_addr, 0, nullptr, &bf_size, &buffer_frames);

    mdw_report local_report{};
    mdw_report& report = out_report ? *out_report : local_report;
    report = {};
    report.device = target.info;
    report.sample_rate = sample_rate;
    report.channels = channels;
    report.container_bits = 32;
    report.valid_bits = 32;
    report.channel_mask = speaker_mask_for_channels(channels);
    report.float_source = 1;
    report.buffer_frames = buffer_frames;
    report.default_period_100ns =
        (sample_rate > 0)
            ? static_cast<int64_t>((uint64_t(buffer_frames) * 10000000ULL) / sample_rate)
            : 100000;
    report.minimum_period_100ns = report.default_period_100ns;

    std::unique_ptr<mdw_recording> recording;
    CaptureCallbackState cb_state;
    cb_state.channels = channels;
    cb_state.non_interleaved = non_interleaved;
    cb_state.timed = timed;
    cb_state.store_pcm = (timed && store_pcm != 0);
    cb_state.sink_context = sink_context;
    cb_state.packet_sink = packet_sink;
    cb_state.report = &report;
    cb_state.scratch.assign(
        static_cast<size_t>(std::max<uint32_t>(buffer_frames * 4, 8192)) * channels, 0.0f);

    if (cb_state.store_pcm) {
      const uint64_t expected_frames =
          (static_cast<uint64_t>(sample_rate) * (duration_ms + 500)) / 1000;
      const uint64_t expected_bytes = expected_frames * channels * sizeof(int16_t);
      const size_t cap = static_cast<size_t>(std::min<uint64_t>(
          kMaxRecordingBytes, std::max<uint64_t>(expected_bytes, 65536u)));
      recording = std::make_unique<mdw_recording>();
      recording->bytes.resize(cap);
      cb_state.recording_buf = recording->bytes.data();
      cb_state.recording_capacity = cap;
    }

    if (format_sink) {
      require_state(format_sink(sink_context, &report) == 0, "Configure live audio format sink");
    }

    AudioDeviceIOProcID io_proc_id = nullptr;
    check_os(
        AudioDeviceCreateIOProcID(
            tap_guard.aggregate_id, capture_io_proc, &cb_state, &io_proc_id),
        "Create CoreAudio tap IOProc");
    struct DestroyIOProc {
      AudioObjectID dev;
      AudioDeviceIOProcID proc;
      bool started = false;
      ~DestroyIOProc() {
        if (started) AudioDeviceStop(dev, proc);
        if (proc) AudioDeviceDestroyIOProcID(dev, proc);
      }
    } io_guard{tap_guard.aggregate_id, io_proc_id, false};

    const auto start = std::chrono::steady_clock::now();
    const auto stop_at = start + std::chrono::milliseconds(duration_ms);
    check_os(
        AudioDeviceStart(tap_guard.aggregate_id, io_proc_id),
        "Start CoreAudio loopback tap");
    io_guard.started = true;

    while (true) {
      if (cancel->is_cancelled()) return 2;
      if (alive.invalidated.load(std::memory_order_acquire) || !device_is_alive(target.id)) {
        fail_throw(kErrFail, "Pinned desktop output endpoint became unavailable");
      }
      if (cb_state.callback_failed.load(std::memory_order_acquire)) {
        fail_throw(
            kErrFail,
            cb_state.failure_reason ? cb_state.failure_reason : "CoreAudio loopback callback failed");
      }
      if (!timed && std::chrono::steady_clock::now() - start > std::chrono::seconds(2) &&
          cb_state.delivered_packets.load(std::memory_order_acquire) == 0) {
        fail_throw(
            kErrFail,
            "No audio packets delivered; grant Screen & System Audio Recording permission");
      }
      if (timed) {
        const auto now = std::chrono::steady_clock::now();
        if (now >= stop_at) break;
        const auto rem =
            std::chrono::duration_cast<std::chrono::milliseconds>(stop_at - now).count();
        if (cancel->wait_ms(static_cast<uint32_t>(std::clamp<int64_t>(rem, 1, 20)))) return 2;
      } else {
        if (cancel->wait_ms(25)) return 2;
      }
    }

    AudioDeviceStop(tap_guard.aggregate_id, io_proc_id);
    io_guard.started = false;

    if (cb_state.callback_failed.load(std::memory_order_acquire)) {
      fail_throw(
          kErrFail,
          cb_state.failure_reason ? cb_state.failure_reason : "CoreAudio loopback callback failed");
    }
    require_state(
        report.packets > 0,
        "No audio packets delivered; grant Screen & System Audio Recording permission");

    report.elapsed_ms =
        std::chrono::duration<double, std::milli>(std::chrono::steady_clock::now() - start).count();
    report.position_gap_frames = cb_state.positions.gaps;
    report.position_regressions = cb_state.positions.regressions;
    report.valid_timestamps = cb_state.positions.valid;
    report.first_device_frame = cb_state.positions.first_frame;
    report.last_device_frame = cb_state.positions.last_frame;
    report.first_qpc_100ns = cb_state.positions.first_qpc;
    report.last_qpc_100ns = cb_state.positions.last_qpc;
    if (report.frames > 0) {
      for (uint32_t c = 0; c < channels; ++c) {
        report.rms[c] =
            std::sqrt(cb_state.sum_squares[c] / static_cast<double>(report.frames));
      }
    }
    if (cb_state.store_pcm && out_recording) {
      recording->bytes.resize(cb_state.recording_written);
      *out_recording = recording.release();
    }
    return 0;
  } catch (const Failure& f) {
    return fail_out(error, f.code, f.operation);
  } catch (const std::bad_alloc&) {
    return fail_out(error, kErrOutOfMemory, "Allocate CoreAudio loopback capture");
  } catch (...) {
    return fail_out(error, kErrFail, "Unexpected CoreAudio loopback capture failure");
  }
}

struct BridgeUnit {
  AudioUnit unit = nullptr;
  bool initialized = false;
  bool started = false;

  ~BridgeUnit() {
    if (unit) {
      if (started) AudioOutputUnitStop(unit);
      if (initialized) AudioUnitUninitialize(unit);
      AudioComponentInstanceDispose(unit);
    }
  }
};

void configure_bridge_unit(AudioDeviceID device_id, AURenderCallback callback, void* userdata,
                           BridgeUnit& out, mdw_bridge_report& report) {
  AudioStreamBasicDescription hw_fmt{};
  UInt32 hw_size = sizeof(hw_fmt);
  AudioObjectPropertyAddress fmt_addr{
      kAudioDevicePropertyStreamFormat,
      kAudioObjectPropertyScopeOutput,
      kAudioObjectPropertyElementMain};
  if (AudioObjectGetPropertyData(device_id, &fmt_addr, 0, nullptr, &hw_size, &hw_fmt) == noErr) {
    report.mix_rate = static_cast<uint32_t>(std::lround(hw_fmt.mSampleRate));
    report.mix_channels = hw_fmt.mChannelsPerFrame;
    report.mix_bits = hw_fmt.mBitsPerChannel ? hw_fmt.mBitsPerChannel : 32;
    report.mix_valid_bits = report.mix_bits;
    report.mix_channel_mask = speaker_mask_for_channels(report.mix_channels);
    report.mix_float = ((hw_fmt.mFormatFlags & kAudioFormatFlagIsFloat) != 0) ? 1 : 0;
  } else {
    report.mix_rate = 48000;
    report.mix_channels = 2;
    report.mix_bits = 32;
    report.mix_valid_bits = 32;
    report.mix_channel_mask = 3;
    report.mix_float = 1;
  }

  UInt32 buf_frames = 480;
  UInt32 bf_size = sizeof(buf_frames);
  AudioObjectPropertyAddress bf_addr{
      kAudioDevicePropertyBufferFrameSize,
      kAudioObjectPropertyScopeGlobal,
      kAudioObjectPropertyElementMain};
  AudioObjectGetPropertyData(device_id, &bf_addr, 0, nullptr, &bf_size, &buf_frames);
  report.buffer_frames = std::clamp<uint32_t>(buf_frames, 64, kMaxSliceFrames);
  report.default_period_100ns =
      (report.mix_rate > 0)
          ? static_cast<int64_t>((uint64_t(report.buffer_frames) * 10000000ULL) / report.mix_rate)
          : 100000;

  UInt32 dev_latency = 0;
  UInt32 lat_size = sizeof(dev_latency);
  AudioObjectPropertyAddress lat_addr{
      kAudioDevicePropertyLatency,
      kAudioObjectPropertyScopeOutput,
      kAudioObjectPropertyElementMain};
  if (AudioObjectGetPropertyData(device_id, &lat_addr, 0, nullptr, &lat_size, &dev_latency) == noErr &&
      report.mix_rate > 0) {
    report.stream_latency_100ns = static_cast<int64_t>(
        (uint64_t(dev_latency + report.buffer_frames) * 10000000ULL) / report.mix_rate);
  }

  AudioComponentDescription desc{};
  desc.componentType = kAudioUnitType_Output;
  desc.componentSubType = kAudioUnitSubType_HALOutput;
  desc.componentManufacturer = kAudioUnitManufacturer_Apple;

  AudioComponent comp = AudioComponentFindNext(nullptr, &desc);
  require_state(comp != nullptr, "Find CoreAudio HALOutput AudioUnit");
  check_os(AudioComponentInstanceNew(comp, &out.unit), "Create CoreAudio HALOutput AudioUnit");

  UInt32 enable_output = 1;
  UInt32 disable_input = 0;
  check_os(
      AudioUnitSetProperty(
          out.unit, kAudioOutputUnitProperty_EnableIO, kAudioUnitScope_Output, 0,
          &enable_output, sizeof(enable_output)),
      "Enable CoreAudio bridge output bus");
  check_os(
      AudioUnitSetProperty(
          out.unit, kAudioOutputUnitProperty_EnableIO, kAudioUnitScope_Input, 1,
          &disable_input, sizeof(disable_input)),
      "Disable CoreAudio bridge input bus");
  check_os(
      AudioUnitSetProperty(
          out.unit, kAudioOutputUnitProperty_CurrentDevice, kAudioUnitScope_Global, 0,
          &device_id, sizeof(device_id)),
      "Bind CoreAudio bridge output device");

  AudioStreamBasicDescription src_fmt{};
  src_fmt.mSampleRate = micdrop::bridge_signal::rate;
  src_fmt.mFormatID = kAudioFormatLinearPCM;
  src_fmt.mFormatFlags = kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked;
  src_fmt.mBytesPerPacket = micdrop::bridge_signal::frame_bytes;
  src_fmt.mFramesPerPacket = 1;
  src_fmt.mBytesPerFrame = micdrop::bridge_signal::frame_bytes;
  src_fmt.mChannelsPerFrame = micdrop::bridge_signal::channels;
  src_fmt.mBitsPerChannel = 32;
  check_os(
      AudioUnitSetProperty(
          out.unit, kAudioUnitProperty_StreamFormat, kAudioUnitScope_Input, 0,
          &src_fmt, sizeof(src_fmt)),
      "Configure CoreAudio bridge 48kHz stereo float32 format");

  UInt32 max_slice = kMaxSliceFrames;
  AudioUnitSetProperty(
      out.unit, kAudioUnitProperty_MaximumFramesPerSlice, kAudioUnitScope_Global, 0,
      &max_slice, sizeof(max_slice));

  AURenderCallbackStruct cb{};
  cb.inputProc = callback;
  cb.inputProcRefCon = userdata;
  check_os(
      AudioUnitSetProperty(
          out.unit, kAudioUnitProperty_SetRenderCallback, kAudioUnitScope_Input, 0,
          &cb, sizeof(cb)),
      "Register CoreAudio bridge render callback");

  check_os(AudioUnitInitialize(out.unit), "Initialize CoreAudio bridge AudioUnit");
  out.initialized = true;
}

struct BridgeCheckState {
  uint64_t total_frames = 0;
  std::atomic<uint64_t> frames_written{0};
  std::atomic<uint64_t> writes{0};
  std::atomic<uint32_t> max_slice{0};
  std::atomic<bool> failed{false};
};

OSStatus bridge_check_proc(
    void* inRefCon,
    AudioUnitRenderActionFlags*,
    const AudioTimeStamp*,
    UInt32,
    UInt32 inNumberFrames,
    AudioBufferList* ioData) {
  auto* st = static_cast<BridgeCheckState*>(inRefCon);
  if (!st || !ioData || ioData->mNumberBuffers == 0 || !ioData->mBuffers[0].mData) return noErr;
  auto* dst = static_cast<uint8_t*>(ioData->mBuffers[0].mData);
  const size_t total_bytes = static_cast<size_t>(inNumberFrames) * micdrop::bridge_signal::frame_bytes;

  uint32_t prev_max = st->max_slice.load(std::memory_order_relaxed);
  while (inNumberFrames > prev_max &&
         !st->max_slice.compare_exchange_weak(prev_max, inNumberFrames, std::memory_order_relaxed)) {
  }

  const uint64_t pos = st->frames_written.load(std::memory_order_relaxed);
  if (pos >= st->total_frames) {
    std::memset(dst, 0, total_bytes);
    return noErr;
  }

  const uint32_t active =
      static_cast<uint32_t>(std::min<uint64_t>(inNumberFrames, st->total_frames - pos));
  if (!micdrop::bridge_signal::fill(
          dst, active * micdrop::bridge_signal::frame_bytes, pos, active)) {
    st->failed.store(true, std::memory_order_release);
    std::memset(dst, 0, total_bytes);
    return noErr;
  }
  if (active < inNumberFrames) {
    std::memset(
        dst + static_cast<size_t>(active) * micdrop::bridge_signal::frame_bytes,
        0,
        static_cast<size_t>(inNumberFrames - active) * micdrop::bridge_signal::frame_bytes);
  }
  st->frames_written.store(pos + active, std::memory_order_release);
  st->writes.fetch_add(1, std::memory_order_relaxed);
  return noErr;
}

struct BridgeLiveState {
  void* context = nullptr;
  mdw_bridge_pull pull = nullptr;
  std::atomic<uint64_t> frames_written{0};
  std::atomic<uint64_t> writes{0};
  std::atomic<uint32_t> max_slice{0};
  std::atomic<bool> failed{false};
};

OSStatus bridge_live_proc(
    void* inRefCon,
    AudioUnitRenderActionFlags*,
    const AudioTimeStamp*,
    UInt32,
    UInt32 inNumberFrames,
    AudioBufferList* ioData) {
  auto* st = static_cast<BridgeLiveState*>(inRefCon);
  if (!st || !ioData || ioData->mNumberBuffers == 0 || !ioData->mBuffers[0].mData) return noErr;
  auto* dst = static_cast<float*>(ioData->mBuffers[0].mData);

  if (st->failed.load(std::memory_order_relaxed)) {
    std::fill_n(dst, static_cast<size_t>(inNumberFrames) * 2, 0.0f);
    return noErr;
  }

  uint32_t prev_max = st->max_slice.load(std::memory_order_relaxed);
  while (inNumberFrames > prev_max &&
         !st->max_slice.compare_exchange_weak(prev_max, inNumberFrames, std::memory_order_relaxed)) {
  }

  uint32_t offset = 0;
  while (offset < inNumberFrames) {
    const uint32_t step = std::min<uint32_t>(inNumberFrames - offset, kMaxPullStepFrames);
    if (st->pull(st->context, dst + static_cast<size_t>(offset) * 2, step) != 0) {
      std::fill_n(
          dst + static_cast<size_t>(offset) * 2,
          static_cast<size_t>(inNumberFrames - offset) * 2,
          0.0f);
      st->failed.store(true, std::memory_order_release);
      return noErr;
    }
    offset += step;
  }

  st->frames_written.fetch_add(inNumberFrames, std::memory_order_release);
  st->writes.fetch_add(1, std::memory_order_relaxed);
  return noErr;
}

}  // namespace

extern "C" mdw_cancel* mdw_cancel_create(void) {
  return new (std::nothrow) mdw_cancel();
}

extern "C" void mdw_cancel_request(mdw_cancel* cancel) {
  if (!cancel) return;
  {
    std::lock_guard<std::mutex> lock(cancel->mutex);
    cancel->requested.store(true, std::memory_order_release);
  }
  cancel->cv.notify_all();
}

extern "C" void mdw_cancel_free(mdw_cancel* cancel) {
  delete cancel;
}

extern "C" int mdw_devices_list(mdw_devices** out, mdw_error* error) {
  if (!out) return fail_out(error, kErrInvalidArg, "Output device list pointer is null");
  *out = nullptr;
  if (error) *error = {};
  try {
    auto list = std::make_unique<mdw_devices>();
    list->items = list_directional_devices(true);
    *out = list.release();
    return 0;
  } catch (const Failure& f) {
    return fail_out(error, f.code, f.operation);
  } catch (const std::bad_alloc&) {
    return fail_out(error, kErrOutOfMemory, "Allocate output device list");
  } catch (...) {
    return fail_out(error, kErrFail, "Unexpected CoreAudio output device enumeration failure");
  }
}

extern "C" int mdw_input_devices_list(mdw_devices** out, mdw_error* error) {
  if (!out) return fail_out(error, kErrInvalidArg, "Input device list pointer is null");
  *out = nullptr;
  if (error) *error = {};
  try {
    auto list = std::make_unique<mdw_devices>();
    list->items = list_directional_devices(false);
    *out = list.release();
    return 0;
  } catch (const Failure& f) {
    return fail_out(error, f.code, f.operation);
  } catch (const std::bad_alloc&) {
    return fail_out(error, kErrOutOfMemory, "Allocate input device list");
  } catch (...) {
    return fail_out(error, kErrFail, "Unexpected CoreAudio input device enumeration failure");
  }
}

extern "C" size_t mdw_devices_count(const mdw_devices* devices) {
  return devices ? devices->items.size() : 0;
}

extern "C" const mdw_device* mdw_devices_get(const mdw_devices* devices, size_t index) {
  if (!devices || index >= devices->items.size()) return nullptr;
  return &devices->items[index];
}

extern "C" void mdw_devices_free(mdw_devices* devices) {
  delete devices;
}

extern "C" const uint8_t* mdw_recording_data(const mdw_recording* recording) {
  if (!recording || recording->bytes.empty()) return nullptr;
  return recording->bytes.data();
}

extern "C" size_t mdw_recording_size(const mdw_recording* recording) {
  return recording ? recording->bytes.size() : 0;
}

extern "C" void mdw_recording_free(mdw_recording* recording) {
  delete recording;
}

extern "C" int mdw_capture_run(
    const char* endpoint_id,
    uint32_t duration_ms,
    int store_pcm,
    mdw_cancel* cancel,
    mdw_report* report,
    mdw_recording** out,
    mdw_error* error) {
  if (out) *out = nullptr;
  if (!endpoint_id || !cancel || !report || duration_ms < 100 || duration_ms > 60000 ||
      (store_pcm != 0 && !out)) {
    return fail_out(error, kErrInvalidArg, "Invalid desktop capture arguments");
  }
  return run_macos_capture(
      endpoint_id, duration_ms, true, store_pcm, cancel, report, out, nullptr, nullptr, nullptr, error);
}

extern "C" int mdw_capture_live(
    const char* endpoint_id,
    mdw_cancel* cancel,
    void* context,
    mdw_format_sink format,
    mdw_packet_sink packet,
    mdw_error* error) {
  if (!endpoint_id || !cancel || !format || !packet) {
    return fail_out(error, kErrInvalidArg, "Invalid live desktop capture arguments");
  }
  return run_macos_capture(
      endpoint_id, 0, false, 0, cancel, nullptr, nullptr, context, format, packet, error);
}

extern "C" int mdw_bridge_check(
    const char* render_endpoint_id,
    uint32_t duration_ms,
    mdw_cancel* cancel,
    mdw_bridge_report* report,
    mdw_error* error) {
  if (!render_endpoint_id || !*render_endpoint_id || !cancel || !report ||
      duration_ms < 100 || duration_ms > 60000) {
    return fail_out(error, kErrInvalidArg, "Invalid bridge check arguments");
  }
  if (error) *error = {};
  *report = {};
  if (cancel->is_cancelled()) return 2;

  try {
    const auto target = resolve_output_device(
        render_endpoint_id, false, "Open selected bridge endpoint; rerun bridge-devices");
    if (cancel->is_cancelled()) return 2;

    AliveListener alive(target.id);
    report->device = target.info;

    BridgeCheckState state;
    state.total_frames =
        (static_cast<uint64_t>(micdrop::bridge_signal::rate) * duration_ms) / 1000;

    BridgeUnit unit;
    configure_bridge_unit(target.id, bridge_check_proc, &state, unit, *report);

    const auto start = std::chrono::steady_clock::now();
    const auto deadline = start + std::chrono::milliseconds(duration_ms) + std::chrono::seconds(5);
    check_os(AudioOutputUnitStart(unit.unit), "Start CoreAudio bridge AudioUnit");
    unit.started = true;

    while (state.frames_written.load(std::memory_order_acquire) < state.total_frames) {
      if (cancel->wait_ms(15)) return 2;
      if (alive.invalidated.load(std::memory_order_acquire) || !device_is_alive(target.id)) {
        fail_throw(kErrFail, "Selected bridge endpoint became unavailable");
      }
      if (state.failed.load(std::memory_order_acquire)) {
        fail_throw(kErrFail, "Generate bridge verification signal");
      }
      if (std::chrono::steady_clock::now() >= deadline) {
        fail_throw(kErrTimeout, "Selected bridge endpoint failed to finish within its deadline");
      }
    }

    const uint32_t drain_ms = std::clamp<uint32_t>(
        (report->buffer_frames * 1000u) / micdrop::bridge_signal::rate + 20u, 20u, 120u);
    if (cancel->wait_ms(drain_ms)) return 2;

    AudioOutputUnitStop(unit.unit);
    unit.started = false;

    report->frames_written = state.frames_written.load(std::memory_order_acquire);
    report->writes = state.writes.load(std::memory_order_relaxed);
    report->maximum_padding_frames =
        std::min<uint32_t>(state.max_slice.load(std::memory_order_relaxed), report->buffer_frames);
    report->elapsed_ms =
        std::chrono::duration<double, std::milli>(std::chrono::steady_clock::now() - start).count();
    return 0;
  } catch (const Failure& f) {
    return fail_out(error, f.code, f.operation);
  } catch (const std::bad_alloc&) {
    return fail_out(error, kErrOutOfMemory, "Allocate bridge setup");
  } catch (...) {
    return fail_out(error, kErrFail, "Unexpected CoreAudio bridge failure");
  }
}

extern "C" int mdw_bridge_live(
    const char* render_endpoint_id,
    mdw_cancel* cancel,
    void* context,
    mdw_bridge_pull pull,
    mdw_bridge_gate gate,
    mdw_bridge_applied applied,
    mdw_bridge_status status,
    mdw_error* error) {
  if (!render_endpoint_id || !*render_endpoint_id || !cancel || !context ||
      !pull || !gate || !applied || !status) {
    return fail_out(error, kErrInvalidArg, "Live bridge requires an explicit endpoint and native callbacks");
  }
  if (error) *error = {};
  if (cancel->is_cancelled()) return 2;

  try {
    require_arg(
        valid_utf8(render_endpoint_id, sizeof(mdw_device{}.id)),
        "Invalid or oversized UTF-8 endpoint ID");
    ResolvedDevice target;
    try {
      target = resolve_output_device(
          render_endpoint_id, false, "Open selected microphone cable; rerun bridge-devices");
    } catch (const Failure& f) {
      fail_throw(f.code ? f.code : kErrNotFound, "Open selected microphone cable; rerun bridge-devices");
    }
    if (cancel->is_cancelled()) return 2;

    AliveListener alive(target.id);
    mdw_bridge_report report{};
    report.device = target.info;

    BridgeLiveState state;
    state.context = context;
    state.pull = pull;

    BridgeUnit unit;
    configure_bridge_unit(target.id, bridge_live_proc, &state, unit, report);

    uint64_t revision = gate(context);
    check_os(AudioOutputUnitStart(unit.unit), "Start CoreAudio microphone cable renderer");
    unit.started = true;
    applied(context, revision);
    status(context, &report);

    uint64_t last_frames = 0;
    auto last_progress = std::chrono::steady_clock::now();

    while (true) {
      if (cancel->wait_ms(20)) return 2;
      if (alive.invalidated.load(std::memory_order_acquire) || !device_is_alive(target.id)) {
        fail_throw(kErrFail, "Selected microphone cable became unavailable");
      }
      if (state.failed.load(std::memory_order_acquire)) {
        fail_throw(kErrFail, "Pull decoded microphone audio");
      }

      const uint64_t current = gate(context);
      if (current != revision) {
        check_os(AudioOutputUnitStop(unit.unit), "Stop microphone cable for mute change");
        unit.started = false;
        check_os(AudioUnitReset(unit.unit, kAudioUnitScope_Global, 0), "Discard queued microphone audio");
        revision = current;
        check_os(AudioOutputUnitStart(unit.unit), "Restart microphone cable after mute change");
        unit.started = true;
        applied(context, revision);
        last_progress = std::chrono::steady_clock::now();
      }

      const uint64_t now_frames = state.frames_written.load(std::memory_order_acquire);
      if (now_frames != last_frames) {
        last_frames = now_frames;
        last_progress = std::chrono::steady_clock::now();
      } else if (std::chrono::steady_clock::now() - last_progress > std::chrono::seconds(5)) {
        fail_throw(kErrTimeout, "Microphone cable stopped consuming audio");
      }

      report.frames_written = now_frames;
      report.writes = state.writes.load(std::memory_order_relaxed);
      report.maximum_padding_frames =
          std::min<uint32_t>(state.max_slice.load(std::memory_order_relaxed), report.buffer_frames);
      status(context, &report);
    }
  } catch (const Failure& f) {
    return fail_out(error, f.code, f.operation);
  } catch (const std::bad_alloc&) {
    return fail_out(error, kErrOutOfMemory, "Allocate microphone cable renderer");
  } catch (...) {
    return fail_out(error, kErrFail, "Unexpected CoreAudio microphone cable failure");
  }
}
