#define WIN32_LEAN_AND_MEAN
#define NOMINMAX
#include <windows.h>
#include <initguid.h>
#include <audioclient.h>
#include <mmdeviceapi.h>
#include <functiondiscoverykeys_devpkey.h>
#include <ks.h>
#include <ksmedia.h>

#include "capture.h"
#include "bridge.h"
#include "bridge_signal.h"
#include "pcm.h"
#include <chrono>
#include <cstdio>
#include <cwchar>
#include <memory>
#include <new>
#include <vector>

namespace {
// Instantiate SDK format constants locally: MinGW's UUID import library does
// not supply the KS data-format symbols used by the MSVC headers.
constexpr GUID pcm_subtype = {STATIC_KSDATAFORMAT_SUBTYPE_PCM};
constexpr GUID float_subtype = {STATIC_KSDATAFORMAT_SUBTYPE_IEEE_FLOAT};

struct Failure { HRESULT hr; const char* operation; };
void check(HRESULT hr, const char* operation) { if (FAILED(hr)) throw Failure{hr, operation}; }
void require(bool ok, const char* message) { if (!ok) throw Failure{E_INVALIDARG, message}; }

int fail(mdw_error* error, HRESULT hr, const char* message) {
  if (error) {
    error->hresult = static_cast<int32_t>(hr);
    std::snprintf(error->message, sizeof(error->message), "%s", message);
  }
  return 1;
}

struct COM {
  bool initialized = false;
  COM() {
    const HRESULT hr = CoInitializeEx(nullptr, COINIT_MULTITHREADED);
    if (hr != RPC_E_CHANGED_MODE) {
      check(hr, "CoInitializeEx");
      initialized = true;
    }
  }
  ~COM() { if (initialized) CoUninitialize(); }
  COM(const COM&) = delete;
  COM& operator=(const COM&) = delete;
};
template<class T> struct Interface {
  T* p = nullptr;
  ~Interface() { if (p) p->Release(); }
  Interface() = default;
  Interface(const Interface&) = delete;
  Interface& operator=(const Interface&) = delete;
  void** address() { return reinterpret_cast<void**>(&p); }
};
struct TaskMemory {
  void operator()(void* p) const { CoTaskMemFree(p); }
};
struct Event {
  HANDLE h;
  explicit Event(bool manual = false) : h(CreateEventW(nullptr, manual, FALSE, nullptr)) {
    if (!h) throw Failure{HRESULT_FROM_WIN32(GetLastError()), "CreateEvent"};
  }
  ~Event() { CloseHandle(h); }
  Event(const Event&) = delete;
  Event& operator=(const Event&) = delete;
};
struct Variant {
  PROPVARIANT value{};
  ~Variant() { PropVariantClear(&value); }
};
struct StopStream {
  IAudioClient* client;
  bool started = false;
  ~StopStream() { if (started) client->Stop(); }
};
struct ReleasePacket {
  IAudioCaptureClient* client;
  UINT32 frames;
  ~ReleasePacket() { if (frames) client->ReleaseBuffer(frames); }
};

void enumerator(Interface<IMMDeviceEnumerator>& out) {
  check(CoCreateInstance(__uuidof(MMDeviceEnumerator), nullptr, CLSCTX_ALL,
      __uuidof(IMMDeviceEnumerator), out.address()), "Create device enumerator");
}
std::unique_ptr<wchar_t, TaskMemory> device_id(IMMDevice* device) {
  wchar_t* raw = nullptr;
  check(device->GetId(&raw), "Read endpoint ID");
  return std::unique_ptr<wchar_t, TaskMemory>(raw);
}
void utf8(const wchar_t* text, char* out, size_t capacity) {
  const int needed = WideCharToMultiByte(CP_UTF8, WC_ERR_INVALID_CHARS, text, -1, nullptr, 0, nullptr, nullptr);
  require(needed > 0 && static_cast<size_t>(needed) <= capacity, "Endpoint text exceeds diagnostic capacity");
  require(WideCharToMultiByte(CP_UTF8, WC_ERR_INVALID_CHARS, text, -1, out, needed, nullptr, nullptr) > 0,
      "Invalid endpoint text");
}
std::vector<wchar_t> wide(const char* text) {
  const int count = MultiByteToWideChar(CP_UTF8, MB_ERR_INVALID_CHARS, text, -1, nullptr, 0);
  require(count > 0 && count <= 1024, "Invalid or oversized UTF-8 endpoint ID");
  std::vector<wchar_t> out(static_cast<size_t>(count));
  require(MultiByteToWideChar(CP_UTF8, MB_ERR_INVALID_CHARS, text, -1, out.data(), count) > 0,
      "Invalid UTF-8 endpoint ID");
  return out;
}
std::unique_ptr<wchar_t, TaskMemory> default_id(IMMDeviceEnumerator* devices, EDataFlow flow = eRender) {
  Interface<IMMDevice> device;
  const HRESULT hr = devices->GetDefaultAudioEndpoint(flow, eMultimedia, &device.p);
  if (hr == HRESULT_FROM_WIN32(ERROR_NOT_FOUND)) return {};
  check(hr, "Read default multimedia endpoint");
  return device_id(device.p);
}
void describe(IMMDevice* device, const wchar_t* default_endpoint, mdw_device& out) {
  const auto id = device_id(device);
  utf8(id.get(), out.id, sizeof(out.id));
  out.default_multimedia = default_endpoint && std::wcscmp(default_endpoint, id.get()) == 0;
  Interface<IPropertyStore> properties;
  check(device->OpenPropertyStore(STGM_READ, &properties.p), "Read endpoint properties");
  Variant name;
  check(properties.p->GetValue(PKEY_Device_FriendlyName, &name.value), "Read endpoint name");
  const auto* label = name.value.vt == VT_LPWSTR && name.value.pwszVal ? name.value.pwszVal : L"Unnamed endpoint";
  utf8(label, out.name, sizeof(out.name));
}

micdrop::pcm::Format format(const WAVEFORMATEX* source, mdw_report& report) {
  uint32_t bits = source->wBitsPerSample;
  uint32_t valid = bits;
  bool floating = source->wFormatTag == WAVE_FORMAT_IEEE_FLOAT;
  bool integer = source->wFormatTag == WAVE_FORMAT_PCM;
  if (source->wFormatTag == WAVE_FORMAT_EXTENSIBLE) {
    require(source->cbSize >= sizeof(WAVEFORMATEXTENSIBLE) - sizeof(WAVEFORMATEX), "Incomplete extensible mix format");
    const auto* ext = reinterpret_cast<const WAVEFORMATEXTENSIBLE*>(source);
    valid = ext->Samples.wValidBitsPerSample;
    floating = IsEqualGUID(ext->SubFormat, float_subtype);
    integer = IsEqualGUID(ext->SubFormat, pcm_subtype);
    report.channel_mask = ext->dwChannelMask;
  }
  const micdrop::pcm::Format result{source->nSamplesPerSec, source->nChannels, bits, valid, source->nBlockAlign, floating};
  require((floating || integer) && micdrop::pcm::supported(result),
      "Unsupported mix format: need float32 or PCM16/24/32, 8..384 kHz, 1..32 channels");
  report.sample_rate = result.rate; report.channels = result.channels;
  report.container_bits = bits; report.valid_bits = valid; report.float_source = floating;
  return result;
}
}  // namespace

struct mdw_devices { std::vector<mdw_device> entries; };
struct mdw_cancel { Event stop{true}; };
struct mdw_recording { std::vector<uint8_t> pcm; size_t used = 0; };

static int devices_list(EDataFlow flow, mdw_devices** out, mdw_error* error) {
  if (!out) return fail(error, E_POINTER, "Missing device-list output");
  *out = nullptr;
  if (error) *error = {};
  try {
    COM apartment;
    Interface<IMMDeviceEnumerator> devices;
    enumerator(devices);
    auto default_endpoint = default_id(devices.p, flow);
    Interface<IMMDeviceCollection> collection;
    check(devices.p->EnumAudioEndpoints(flow, DEVICE_STATE_ACTIVE, &collection.p), "Enumerate active endpoints");
    UINT count = 0;
    check(collection.p->GetCount(&count), "Count active outputs");
    require(count <= 4096, "Too many endpoints for diagnostic enumeration");
    auto list = std::make_unique<mdw_devices>();
    list->entries.resize(count);
    for (UINT i = 0; i < count; ++i) {
      Interface<IMMDevice> device;
      check(collection.p->Item(i, &device.p), "Read endpoint");
      describe(device.p, default_endpoint.get(), list->entries[i]);
    }
    *out = list.release();
    return 0;
  } catch (const Failure& e) { return fail(error, e.hr, e.operation); }
    catch (const std::bad_alloc&) { return fail(error, E_OUTOFMEMORY, "Allocate device list"); }
    catch (...) { return fail(error, E_FAIL, "Unexpected native enumeration failure"); }
}
extern "C" int mdw_devices_list(mdw_devices** out, mdw_error* error) {
  return devices_list(eRender, out, error);
}
extern "C" int mdw_input_devices_list(mdw_devices** out, mdw_error* error) {
  return devices_list(eCapture, out, error);
}
extern "C" size_t mdw_devices_count(const mdw_devices* devices) { return devices ? devices->entries.size() : 0; }
extern "C" const mdw_device* mdw_devices_get(const mdw_devices* devices, size_t index) {
  return devices && index < devices->entries.size() ? &devices->entries[index] : nullptr;
}
extern "C" void mdw_devices_free(mdw_devices* devices) { delete devices; }
extern "C" mdw_cancel* mdw_cancel_create(void) {
  try { return new mdw_cancel; } catch (...) { return nullptr; }
}
extern "C" void mdw_cancel_request(mdw_cancel* cancel) { if (cancel) SetEvent(cancel->stop.h); }
extern "C" void mdw_cancel_free(mdw_cancel* cancel) { delete cancel; }

static int capture_run(const char* endpoint_id, uint32_t duration_ms, int store_pcm,
    mdw_cancel* cancel, mdw_report* report, mdw_recording** out, mdw_error* error,
    void* context, mdw_format_sink format_sink, mdw_packet_sink packet_sink) {
  if (out) *out = nullptr;
  if (report) *report = {};
  if (error) *error = {};
  if (!out || !report || !cancel || !endpoint_id || (!packet_sink && duration_ms < 100) || duration_ms > 60000 ||
      (store_pcm != 0 && store_pcm != 1)) return fail(error, E_INVALIDARG, "Invalid capture arguments");
  try {
    if (WaitForSingleObject(cancel->stop.h, 0) == WAIT_OBJECT_0) return 2;
    COM apartment;
    Interface<IMMDeviceEnumerator> devices;
    enumerator(devices);
    Interface<IMMDevice> device;
    if (*endpoint_id == '\0') {
      check(devices.p->GetDefaultAudioEndpoint(eRender, eMultimedia, &device.p), "Select default multimedia output");
    } else {
      const auto id = wide(endpoint_id);
      check(devices.p->GetDevice(id.data(), &device.p), "Select output ID (run devices to refresh IDs)");
    }
    Interface<IMMEndpoint> endpoint;
    check(device.p->QueryInterface(__uuidof(IMMEndpoint), endpoint.address()), "Query endpoint direction");
    EDataFlow flow = eAll;
    check(endpoint.p->GetDataFlow(&flow), "Read endpoint direction");
    require(flow == eRender, "Selected endpoint must be an output, not a microphone");
    DWORD state = 0;
    check(device.p->GetState(&state), "Read endpoint state");
    require((state & DEVICE_STATE_ACTIVE) != 0, "Selected output is inactive; run devices to refresh IDs");
    const auto default_endpoint = default_id(devices.p);
    describe(device.p, default_endpoint.get(), report->device);

    // Declare event before client so the event outlives the initialized stream.
    Event ready;
    Interface<IAudioClient> client;
    check(device.p->Activate(__uuidof(IAudioClient), CLSCTX_ALL, nullptr, client.address()), "Activate output capture");
    WAVEFORMATEX* raw_format = nullptr;
    check(client.p->GetMixFormat(&raw_format), "Get shared-mode mix format");
    const std::unique_ptr<WAVEFORMATEX, TaskMemory> mix(raw_format);
    const auto pcm_format = format(mix.get(), *report);
    REFERENCE_TIME period = 0, minimum = 0;
    check(client.p->GetDevicePeriod(&period, &minimum), "Get device periods");
    report->default_period_100ns = period; report->minimum_period_100ns = minimum;
    check(client.p->Initialize(AUDCLNT_SHAREMODE_SHARED,
        AUDCLNT_STREAMFLAGS_LOOPBACK | AUDCLNT_STREAMFLAGS_EVENTCALLBACK,
        0, 0, mix.get(), nullptr), "Initialize shared event-driven loopback");
    check(client.p->SetEventHandle(ready.h), "Set capture event");
    UINT32 buffer_frames = 0;
    check(client.p->GetBufferSize(&buffer_frames), "Get actual endpoint buffer size");
    require(buffer_frames > 0 && buffer_frames <= pcm_format.rate * 2, "Unexpected endpoint buffer size");
    report->buffer_frames = buffer_frames;
    Interface<IAudioCaptureClient> capture;
    check(client.p->GetService(__uuidof(IAudioCaptureClient), capture.address()), "Get loopback capture service");

    // Allocate and touch memory before Start. The live loop only decodes,
    // accumulates diagnostics, and copies into this fixed recording capacity.
    std::vector<float> block(static_cast<size_t>(buffer_frames) * pcm_format.channels);
    auto recording = std::make_unique<mdw_recording>();
    if (store_pcm) {
      const uint64_t capacity_frames = (uint64_t(duration_ms) * pcm_format.rate + 999) / 1000 + buffer_frames;
      const uint64_t capacity = capacity_frames * pcm_format.channels * 2;
      require(capacity <= 64 * 1024 * 1024, "Recording exceeds 64 MiB limit; use a shorter duration or omit --output");
      recording->pcm.resize(static_cast<size_t>(capacity));
    }
    double sums[MDW_MAX_CHANNELS]{};
    micdrop::pcm::Positions positions;
    StopStream stop{client.p};
    if (format_sink) require(format_sink(context, report) == 0, "Streaming adapter rejected the device format");
    if (WaitForSingleObject(cancel->stop.h, 0) == WAIT_OBJECT_0) return 2;
    check(client.p->Start(), "Start loopback capture");
    stop.started = true;
    const auto start = std::chrono::steady_clock::now();
    const auto deadline = duration_ms ? start + std::chrono::milliseconds(duration_ms) : std::chrono::steady_clock::time_point::max();
    HANDLE events[] = {cancel->stop.h, ready.h};
    for (;;) {
      if (WaitForSingleObject(cancel->stop.h, 0) == WAIT_OBJECT_0) return 2;
      const auto now = std::chrono::steady_clock::now();
      if (now >= deadline) break;
      const auto remaining = duration_ms ? std::chrono::duration_cast<std::chrono::milliseconds>(deadline - now).count() : 100;
      const auto wait_ms = static_cast<DWORD>(std::clamp<int64_t>(remaining, 1, 100));
      const DWORD result = WaitForMultipleObjects(2, events, FALSE, wait_ms);
      if (result == WAIT_OBJECT_0) return 2;
      if (result == WAIT_FAILED) throw Failure{HRESULT_FROM_WIN32(GetLastError()), "Wait for capture packet"};
      // Also query on timeout: detects endpoint invalidation during idle output.
      for (;;) {
        if (WaitForSingleObject(cancel->stop.h, 0) == WAIT_OBJECT_0) return 2;
        if (std::chrono::steady_clock::now() >= deadline) break;
        UINT32 next = 0;
        check(capture.p->GetNextPacketSize(&next), "Get next packet (endpoint may have changed; rerun devices)");
        if (next == 0) break;
        BYTE* data = nullptr;
        UINT32 frames = 0;
        DWORD flags = 0;
        UINT64 device_frame = 0, qpc = 0;
        const HRESULT hr = capture.p->GetBuffer(&data, &frames, &flags, &device_frame, &qpc);
        check(hr, "Get capture packet (endpoint may have changed; rerun devices)");
        if (hr == AUDCLNT_S_BUFFER_EMPTY || frames == 0) break;
        ReleasePacket release{capture.p, frames};
        require(frames <= buffer_frames, "Capture packet exceeds allocated buffer");
        const bool silent = (flags & AUDCLNT_BUFFERFLAGS_SILENT) != 0;
        require(micdrop::pcm::decode(pcm_format, data, static_cast<size_t>(frames) * pcm_format.block_align,
            frames, silent, block.data(), block.size()), "Invalid PCM capture packet");
        // Release Windows' buffer before processing the private float block.
        const HRESULT released = capture.p->ReleaseBuffer(frames);
        release.frames = 0;
        check(released, "Release capture packet");
        if (packet_sink) require(packet_sink(context, block.data(), frames, flags) == 0, "Streaming PCM sink stopped capture");
        const size_t sample_count = static_cast<size_t>(frames) * pcm_format.channels;
        if (store_pcm) require(sample_count * 2 <= recording->pcm.size() - recording->used,
            "Recording capacity exhausted; retry with a shorter duration");
        for (size_t i = 0; i < sample_count; ++i) {
          float sample = block[i];
          if (!std::isfinite(sample)) { ++report->nonfinite_samples; sample = 0; }
          const double magnitude = std::abs(double(sample));
          if (magnitude > 1.0) ++report->clipped_samples;
          const size_t channel = i % pcm_format.channels;
          report->peak[channel] = std::max(report->peak[channel], magnitude);
          sums[channel] += double(sample) * sample;
          if (store_pcm) {
            const auto value = static_cast<uint16_t>(micdrop::pcm::to_pcm16(sample));
            recording->pcm[recording->used++] = static_cast<uint8_t>(value);
            recording->pcm[recording->used++] = static_cast<uint8_t>(value >> 8);
          }
        }
        const bool discontinuity = (flags & AUDCLNT_BUFFERFLAGS_DATA_DISCONTINUITY) != 0;
        if (report->packets == 0) report->first_packet_discontinuity = discontinuity;
        else if (discontinuity) ++report->discontinuities;
        const bool bad_time = (flags & AUDCLNT_BUFFERFLAGS_TIMESTAMP_ERROR) != 0;
        if (bad_time) ++report->timestamp_errors;
        positions.add(device_frame, qpc, frames, bad_time);
        if (report->packets == 0) report->min_packet_frames = frames;
        report->min_packet_frames = std::min(report->min_packet_frames, frames);
        report->max_packet_frames = std::max(report->max_packet_frames, frames);
        ++report->packets; report->frames += frames;
        if (silent) report->silent_flag_frames += frames;
      }
    }
    check(client.p->Stop(), "Stop loopback capture");
    stop.started = false;
    report->elapsed_ms = std::chrono::duration<double, std::milli>(std::chrono::steady_clock::now() - start).count();
    report->valid_timestamps = positions.valid;
    report->first_device_frame = positions.first_frame; report->last_device_frame = positions.last_frame;
    report->first_qpc_100ns = positions.first_qpc; report->last_qpc_100ns = positions.last_qpc;
    report->position_gap_frames = positions.gaps; report->position_regressions = positions.regressions;
    if (report->frames) for (uint32_t i = 0; i < pcm_format.channels; ++i)
      report->rms[i] = std::sqrt(sums[i] / static_cast<double>(report->frames));
    *out = recording.release();
    return 0;
  } catch (const Failure& e) { return fail(error, e.hr, e.operation); }
    catch (const std::bad_alloc&) { return fail(error, E_OUTOFMEMORY, "Allocate capture buffers"); }
    catch (...) { return fail(error, E_FAIL, "Unexpected native capture failure"); }
}
extern "C" int mdw_capture_run(const char* endpoint_id, uint32_t duration_ms, int store_pcm,
    mdw_cancel* cancel, mdw_report* report, mdw_recording** out, mdw_error* error) {
  return capture_run(endpoint_id, duration_ms, store_pcm, cancel, report, out, error, nullptr, nullptr, nullptr);
}
extern "C" int mdw_capture_live(const char* endpoint_id, mdw_cancel* cancel, void* context,
    mdw_format_sink format_sink, mdw_packet_sink packet_sink, mdw_error* error) {
  if (!format_sink || !packet_sink) return fail(error, E_INVALIDARG, "Missing streaming sink");
  mdw_report report{};
  mdw_recording* recording = nullptr;
  const int result = capture_run(endpoint_id, 0, 0, cancel, &report, &recording, error, context, format_sink, packet_sink);
  delete recording;
  return result;
}
extern "C" const uint8_t* mdw_recording_data(const mdw_recording* recording) {
  return recording && recording->used ? recording->pcm.data() : nullptr;
}
extern "C" size_t mdw_recording_size(const mdw_recording* recording) { return recording ? recording->used : 0; }
extern "C" void mdw_recording_free(mdw_recording* recording) { delete recording; }


extern "C" int mdw_bridge_check(const char* endpoint_id, uint32_t duration_ms,
    mdw_cancel* cancel, mdw_bridge_report* report, mdw_error* error) {
  if (!endpoint_id || !*endpoint_id || !cancel || !report)
    return fail(error, E_INVALIDARG, "Bridge requires an explicit render endpoint, cancellation token and report");
  *report = {};
  if (error) *error = {};
  if (duration_ms < 100 || duration_ms > 60000)
    return fail(error, E_INVALIDARG, "Bridge duration must be 100..60000 ms");
  if (WaitForSingleObject(cancel->stop.h, 0) == WAIT_OBJECT_0) return 2;
  try {
    COM apartment;
    Interface<IMMDeviceEnumerator> devices;
    enumerator(devices);
    Interface<IMMDevice> device;
    const auto id = wide(endpoint_id);
    check(devices.p->GetDevice(id.data(), &device.p), "Open selected bridge endpoint; rerun bridge-devices");
    DWORD state = 0;
    check(device.p->GetState(&state), "Read bridge endpoint state");
    require(state == DEVICE_STATE_ACTIVE, "Selected bridge endpoint is not active");
    Interface<IMMEndpoint> endpoint;
    check(device.p->QueryInterface(__uuidof(IMMEndpoint), endpoint.address()), "Read bridge endpoint direction");
    EDataFlow flow = eAll;
    check(endpoint.p->GetDataFlow(&flow), "Read bridge endpoint direction");
    require(flow == eRender, "Choose the cable's render endpoint, not its recording endpoint");
    auto default_endpoint = default_id(devices.p);
    describe(device.p, default_endpoint.get(), report->device);
    Event ready;
    Interface<IAudioClient> client;
    check(device.p->Activate(__uuidof(IAudioClient), CLSCTX_ALL, nullptr, client.address()), "Activate selected bridge output");
    WAVEFORMATEX* raw_mix = nullptr;
    check(client.p->GetMixFormat(&raw_mix), "Read bridge mix format");
    std::unique_ptr<WAVEFORMATEX, TaskMemory> mix(raw_mix);
    mdw_report mix_report{};
    format(mix.get(), mix_report);
    report->mix_rate = mix_report.sample_rate; report->mix_channels = mix_report.channels;
    report->mix_bits = mix_report.container_bits; report->mix_valid_bits = mix_report.valid_bits;
    report->mix_channel_mask = mix_report.channel_mask; report->mix_float = mix_report.float_source;
    REFERENCE_TIME minimum_period = 0;
    check(client.p->GetDevicePeriod(&report->default_period_100ns, &minimum_period), "Read bridge device period");
    constexpr uint32_t source_rate = micdrop::bridge_signal::rate;
    WAVEFORMATEX source{WAVE_FORMAT_IEEE_FLOAT, 2, source_rate, source_rate * 8, 8, 32, 0};
    check(client.p->Initialize(AUDCLNT_SHAREMODE_SHARED,
        AUDCLNT_STREAMFLAGS_EVENTCALLBACK | AUDCLNT_STREAMFLAGS_AUTOCONVERTPCM | AUDCLNT_STREAMFLAGS_SRC_DEFAULT_QUALITY,
        0, 0, &source, nullptr), "Initialize shared bridge renderer");
    check(client.p->SetEventHandle(ready.h), "Set bridge render event");
    struct StopRender {
      IAudioClient* client;
      bool started = false;
      ~StopRender() { if (started) client->Stop(); client->Reset(); }
    } stop{client.p};
    check(client.p->GetBufferSize(&report->buffer_frames), "Read bridge buffer capacity");
    require(report->buffer_frames > 0 && report->buffer_frames <= 4800, "Microphone cable buffer exceeds the 100ms live limit");
    check(client.p->GetStreamLatency(&report->stream_latency_100ns), "Read reported bridge stream latency");
    Interface<IAudioRenderClient> render;
    check(client.p->GetService(__uuidof(IAudioRenderClient), render.address()), "Get bridge render service");
    const uint64_t total_frames = uint64_t(duration_ms) * source_rate / 1000;
    auto write = [&](UINT32 frames) {
      if (!frames) return;
      BYTE* data = nullptr;
      check(render.p->GetBuffer(frames, &data), "Get bridge render buffer");
      struct Packet {
        IAudioRenderClient* client;
        UINT32 frames;
        ~Packet() { if (frames) client->ReleaseBuffer(frames, AUDCLNT_BUFFERFLAGS_SILENT); }
      } packet{render.p, frames};
      require(micdrop::bridge_signal::fill(data, size_t(frames) * 8, report->frames_written, frames), "Fill bridge test signal");
      const HRESULT hr = render.p->ReleaseBuffer(frames, 0);
      packet.frames = 0;
      check(hr, "Submit bridge render buffer");
      report->frames_written += frames; ++report->writes;
    };
    if (WaitForSingleObject(cancel->stop.h, 0) == WAIT_OBJECT_0) return 2;
    write(static_cast<UINT32>(std::min<uint64_t>(total_frames, report->buffer_frames)));
    check(client.p->Start(), "Start selected bridge output");
    stop.started = true;
    const auto start = std::chrono::steady_clock::now();
    const auto deadline = start + std::chrono::milliseconds(duration_ms + 5000);
    HANDLE events[] = {cancel->stop.h, ready.h};
    for (;;) {
      if (WaitForSingleObject(cancel->stop.h, 0) == WAIT_OBJECT_0) return 2;
      if (std::chrono::steady_clock::now() >= deadline)
        throw Failure{HRESULT_FROM_WIN32(ERROR_TIMEOUT), "Selected bridge endpoint failed to finish within its deadline"};
      UINT32 padding = 0;
      check(client.p->GetCurrentPadding(&padding), "Read bridge queue; endpoint may have changed");
      require(padding <= report->buffer_frames, "Bridge padding exceeds buffer capacity");
      report->maximum_padding_frames = std::max(report->maximum_padding_frames, padding);
      if (report->frames_written == total_frames && padding == 0) break;
      if (report->frames_written < total_frames) {
        if (padding == 0) ++report->empty_buffer_events;
        const auto available = report->buffer_frames - padding;
        write(static_cast<UINT32>(std::min<uint64_t>(available, total_frames - report->frames_written)));
      }
      const DWORD waited = WaitForMultipleObjects(2, events, FALSE, 100);
      if (waited == WAIT_OBJECT_0) return 2;
      if (waited == WAIT_FAILED) throw Failure{HRESULT_FROM_WIN32(GetLastError()), "Wait for bridge renderer"};
      // Also inspect padding on timeout: detects invalidation without switching
      // to another device and bounds stalled drivers without busy polling.
    }
    report->elapsed_ms = std::chrono::duration<double, std::milli>(std::chrono::steady_clock::now() - start).count();
    return 0;
  } catch (const Failure& e) { return fail(error, e.hr, e.operation); }
    catch (const std::bad_alloc&) { return fail(error, E_OUTOFMEMORY, "Allocate bridge setup"); }
    catch (...) { return fail(error, E_FAIL, "Unexpected native bridge failure"); }
}

extern "C" int mdw_bridge_live(const char* endpoint_id, mdw_cancel* cancel, void* context,
    mdw_bridge_pull pull, mdw_bridge_gate gate, mdw_bridge_applied applied,
    mdw_bridge_status status, mdw_error* error) {
  if (!endpoint_id || !*endpoint_id || !cancel || !context || !pull || !gate || !applied || !status)
    return fail(error, E_INVALIDARG, "Live bridge requires an explicit endpoint and native callbacks");
  if (error) *error = {};
  if (WaitForSingleObject(cancel->stop.h, 0) == WAIT_OBJECT_0) return 2;
  try {
    COM apartment;
    Interface<IMMDeviceEnumerator> devices;
    enumerator(devices);
    Interface<IMMDevice> device;
    const auto id = wide(endpoint_id);
    check(devices.p->GetDevice(id.data(), &device.p), "Open selected microphone cable; rerun bridge-devices");
    DWORD device_state = 0;
    check(device.p->GetState(&device_state), "Read microphone cable state");
    require(device_state == DEVICE_STATE_ACTIVE, "Selected microphone cable is not active");
    Interface<IMMEndpoint> endpoint;
    check(device.p->QueryInterface(__uuidof(IMMEndpoint), endpoint.address()), "Read microphone cable direction");
    EDataFlow flow = eAll;
    check(endpoint.p->GetDataFlow(&flow), "Read microphone cable direction");
    require(flow == eRender, "Choose the cable render endpoint, not its recording endpoint");
    mdw_bridge_report report{};
    auto default_endpoint = default_id(devices.p);
    describe(device.p, default_endpoint.get(), report.device);
    Event ready;
    Interface<IAudioClient> client;
    check(device.p->Activate(__uuidof(IAudioClient), CLSCTX_ALL, nullptr, client.address()), "Activate microphone cable");
    WAVEFORMATEX* raw_mix = nullptr;
    check(client.p->GetMixFormat(&raw_mix), "Read microphone cable mix format");
    std::unique_ptr<WAVEFORMATEX, TaskMemory> mix(raw_mix);
    mdw_report decoded{};
    format(mix.get(), decoded);
    report.mix_rate = decoded.sample_rate; report.mix_channels = decoded.channels;
    report.mix_bits = decoded.container_bits; report.mix_valid_bits = decoded.valid_bits;
    report.mix_channel_mask = decoded.channel_mask; report.mix_float = decoded.float_source;
    REFERENCE_TIME minimum_period = 0;
    check(client.p->GetDevicePeriod(&report.default_period_100ns, &minimum_period), "Read microphone cable period");
    WAVEFORMATEX source{WAVE_FORMAT_IEEE_FLOAT, 2, 48000, 48000 * 8, 8, 32, 0};
    check(client.p->Initialize(AUDCLNT_SHAREMODE_SHARED,
        AUDCLNT_STREAMFLAGS_EVENTCALLBACK | AUDCLNT_STREAMFLAGS_AUTOCONVERTPCM | AUDCLNT_STREAMFLAGS_SRC_DEFAULT_QUALITY,
        0, 0, &source, nullptr), "Initialize microphone cable renderer");
    check(client.p->SetEventHandle(ready.h), "Set microphone cable event");
    struct StopRender {
      IAudioClient* client;
      bool started = false;
      ~StopRender() { if (started) client->Stop(); client->Reset(); }
    } stop{client.p};
    check(client.p->GetBufferSize(&report.buffer_frames), "Read microphone cable buffer");
    require(report.buffer_frames > 0 && report.buffer_frames <= 4800, "Microphone cable buffer exceeds the 100ms live limit");
    check(client.p->GetStreamLatency(&report.stream_latency_100ns), "Read microphone cable stream latency");
    Interface<IAudioRenderClient> render;
    check(client.p->GetService(__uuidof(IAudioRenderClient), render.address()), "Get microphone cable render service");
    auto write = [&](UINT32 frames) {
      if (!frames) return;
      BYTE* data = nullptr;
      check(render.p->GetBuffer(frames, &data), "Get microphone cable buffer");
      struct Packet {
        IAudioRenderClient* client; UINT32 frames;
        ~Packet() { if (frames) client->ReleaseBuffer(frames, AUDCLNT_BUFFERFLAGS_SILENT); }
      } packet{render.p, frames};
      require(pull(context, reinterpret_cast<float*>(data), frames) == 0, "Pull decoded microphone audio");
      const HRESULT hr = render.p->ReleaseBuffer(frames, 0);
      packet.frames = 0;
      check(hr, "Submit microphone cable buffer");
      report.frames_written += frames; ++report.writes;
    };
    auto revision = gate(context);
    write(report.buffer_frames);
    check(client.p->Start(), "Start microphone cable renderer");
    stop.started = true;
    applied(context, revision); status(context, &report);
    auto last_progress = std::chrono::steady_clock::now();
    HANDLE events[] = {cancel->stop.h, ready.h};
    for (;;) {
      if (WaitForSingleObject(cancel->stop.h, 0) == WAIT_OBJECT_0) return 2;
      const auto current = gate(context);
      if (current != revision) {
        check(client.p->Stop(), "Stop microphone cable for mute change");
        stop.started = false;
        check(client.p->Reset(), "Discard queued microphone audio");
        revision = current;
        write(report.buffer_frames);
        check(client.p->Start(), "Restart microphone cable after mute change");
        stop.started = true;
        applied(context, revision);
        last_progress = std::chrono::steady_clock::now();
      }
      UINT32 padding = 0;
      check(client.p->GetCurrentPadding(&padding), "Read microphone cable queue; endpoint may have changed");
      require(padding <= report.buffer_frames, "Microphone cable padding exceeds capacity");
      report.maximum_padding_frames = std::max(report.maximum_padding_frames, padding);
      if (padding < report.buffer_frames) {
        if (padding == 0) ++report.empty_buffer_events;
        write(report.buffer_frames - padding);
        last_progress = std::chrono::steady_clock::now();
      } else if (std::chrono::steady_clock::now() - last_progress > std::chrono::seconds(5)) {
        throw Failure{HRESULT_FROM_WIN32(ERROR_TIMEOUT), "Microphone cable stopped consuming audio"};
      }
      status(context, &report);
      const DWORD waited = WaitForMultipleObjects(2, events, FALSE, 100);
      if (waited == WAIT_OBJECT_0) return 2;
      if (waited == WAIT_FAILED) throw Failure{HRESULT_FROM_WIN32(GetLastError()), "Wait for microphone cable renderer"};
    }
  } catch (const Failure& e) { return fail(error, e.hr, e.operation); }
    catch (const std::bad_alloc&) { return fail(error, E_OUTOFMEMORY, "Allocate microphone cable renderer"); }
    catch (...) { return fail(error, E_FAIL, "Unexpected microphone cable failure"); }
}
