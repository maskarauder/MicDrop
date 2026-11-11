// SPDX-License-Identifier: MPL-2.0
//go:build linux && amd64

#include "capture.h"
#include "bridge.h"
#include "bridge_signal.h"
#include "pcm.h"

#include <dlfcn.h>
#include <errno.h>

#include <algorithm>
#include <array>
#include <atomic>
#include <chrono>
#include <cmath>
#include <condition_variable>
#include <cstdint>
#include <cstdio>
#include <cstring>
#include <limits>
#include <memory>
#include <mutex>
#include <new>
#include <string>
#include <thread>
#include <vector>

namespace {

constexpr int32_t kErrInvalidArg = -2147024809;   // E_INVALIDARG
constexpr int32_t kErrOutOfMemory = -2147024882;  // E_OUTOFMEMORY
constexpr int32_t kErrFail = -2147467259;         // E_FAIL
constexpr int32_t kErrNotFound = -2147023728;     // HRESULT_FROM_WIN32(ERROR_NOT_FOUND)
constexpr int32_t kErrTimeout = -2147023436;      // HRESULT_FROM_WIN32(ERROR_TIMEOUT)

constexpr size_t kMaxRecordingBytes = 64u * 1024u * 1024u;
constexpr uint32_t kBridgeBufferFrames = 960;  // 20 ms at 48 kHz (well within <=100 ms contract)

struct Failure {
  int32_t code;
  const char* operation;
};

[[noreturn]] void fail_throw(int32_t code, const char* operation) {
  throw Failure{code, operation};
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

void copy_checked_utf8(const char* src, char* dst, size_t capacity, const char* label) {
  require_state(src != nullptr && valid_utf8(src, capacity), label, kErrInvalidArg);
  const size_t len = std::strlen(src) + 1;
  std::memcpy(dst, src, len);
}

uint64_t monotonic_100ns() {
  const auto now = std::chrono::steady_clock::now().time_since_epoch();
  return static_cast<uint64_t>(
      std::chrono::duration_cast<std::chrono::nanoseconds>(now).count() / 100);
}

// Self-contained PulseAudio v16.1 C ABI declarations loaded dynamically from
// libpulse.so.0 so builds require no system -dev headers and run identically
// against PipeWire (pipewire-pulse) and PulseAudio.
constexpr size_t kPaChannelsMax = 32;
constexpr uint32_t kPaInvalidIndex = 0xFFFFFFFFu;

enum pa_sample_format_t : int {
  PA_SAMPLE_U8 = 0,
  PA_SAMPLE_ALAW = 1,
  PA_SAMPLE_ULAW = 2,
  PA_SAMPLE_S16LE = 3,
  PA_SAMPLE_S16BE = 4,
  PA_SAMPLE_FLOAT32LE = 5,
  PA_SAMPLE_FLOAT32BE = 6,
  PA_SAMPLE_S32LE = 7,
  PA_SAMPLE_S32BE = 8,
  PA_SAMPLE_S24LE = 9,
  PA_SAMPLE_S24BE = 10,
  PA_SAMPLE_S24_32LE = 11,
  PA_SAMPLE_S24_32BE = 12,
  PA_SAMPLE_INVALID = -1,
};

enum pa_context_state_t : int {
  PA_CONTEXT_UNCONNECTED = 0,
  PA_CONTEXT_CONNECTING = 1,
  PA_CONTEXT_AUTHORIZING = 2,
  PA_CONTEXT_SETTING_NAME = 3,
  PA_CONTEXT_READY = 4,
  PA_CONTEXT_FAILED = 5,
  PA_CONTEXT_TERMINATED = 6,
};

enum pa_stream_state_t : int {
  PA_STREAM_UNCONNECTED = 0,
  PA_STREAM_CREATING = 1,
  PA_STREAM_READY = 2,
  PA_STREAM_FAILED = 3,
  PA_STREAM_TERMINATED = 4,
};

enum pa_operation_state_t : int {
  PA_OPERATION_RUNNING = 0,
  PA_OPERATION_DONE = 1,
  PA_OPERATION_CANCELLED = 2,
};

enum pa_context_flags_t : int {
  PA_CONTEXT_NOFLAGS = 0x0000,
  PA_CONTEXT_NOAUTOSPAWN = 0x0001,
};

enum pa_stream_flags_t : unsigned int {
  PA_STREAM_NOFLAGS = 0x0000u,
  PA_STREAM_START_CORKED = 0x0001u,
  PA_STREAM_INTERPOLATE_TIMING = 0x0002u,
  PA_STREAM_AUTO_TIMING_UPDATE = 0x0008u,
  PA_STREAM_DONT_MOVE = 0x0200u,
  PA_STREAM_ADJUST_LATENCY = 0x2000u,
  PA_STREAM_FAIL_ON_SUSPEND = 0x20000u,
};

enum pa_seek_mode_t : int {
  PA_SEEK_RELATIVE = 0,
};

using pa_usec_t = uint64_t;
using pa_volume_t = uint32_t;
using pa_channel_position_t = int;

struct pa_mainloop;
struct pa_mainloop_api;
struct pa_context;
struct pa_operation;
struct pa_stream;
struct pa_proplist;
struct pa_spawn_api;
struct pa_format_info;
struct pa_sink_port_info;
struct pa_source_port_info;

struct pa_sample_spec {
  pa_sample_format_t format;
  uint32_t rate;
  uint8_t channels;
};

struct pa_channel_map {
  uint8_t channels;
  pa_channel_position_t map[kPaChannelsMax];
};

struct pa_cvolume {
  uint8_t channels;
  pa_volume_t values[kPaChannelsMax];
};

struct pa_buffer_attr {
  uint32_t maxlength;
  uint32_t tlength;
  uint32_t prebuf;
  uint32_t minreq;
  uint32_t fragsize;
};

struct pa_server_info {
  const char* user_name;
  const char* host_name;
  const char* server_version;
  const char* server_name;
  pa_sample_spec sample_spec;
  const char* default_sink_name;
  const char* default_source_name;
  uint32_t cookie;
  pa_channel_map channel_map;
};

struct pa_sink_info {
  const char* name;
  uint32_t index;
  const char* description;
  pa_sample_spec sample_spec;
  pa_channel_map channel_map;
  uint32_t owner_module;
  pa_cvolume volume;
  int mute;
  uint32_t monitor_source;
  const char* monitor_source_name;
  pa_usec_t latency;
  const char* driver;
  int flags;
  pa_proplist* proplist;
  pa_usec_t configured_latency;
  pa_volume_t base_volume;
  int state;
  uint32_t n_volume_steps;
  uint32_t card;
  uint32_t n_ports;
  pa_sink_port_info** ports;
  pa_sink_port_info* active_port;
  uint8_t n_formats;
  pa_format_info** formats;
};

struct pa_source_info {
  const char* name;
  uint32_t index;
  const char* description;
  pa_sample_spec sample_spec;
  pa_channel_map channel_map;
  uint32_t owner_module;
  pa_cvolume volume;
  int mute;
  uint32_t monitor_of_sink;
  const char* monitor_of_sink_name;
  pa_usec_t latency;
  const char* driver;
  int flags;
  pa_proplist* proplist;
  pa_usec_t configured_latency;
  pa_volume_t base_volume;
  int state;
  uint32_t n_volume_steps;
  uint32_t card;
  uint32_t n_ports;
  pa_source_port_info** ports;
  pa_source_port_info* active_port;
  uint8_t n_formats;
  pa_format_info** formats;
};

using pa_server_info_cb_t = void (*)(pa_context*, const pa_server_info*, void*);
using pa_sink_info_cb_t = void (*)(pa_context*, const pa_sink_info*, int, void*);
using pa_source_info_cb_t = void (*)(pa_context*, const pa_source_info*, int, void*);
using pa_stream_success_cb_t = void (*)(pa_stream*, int, void*);
using pa_stream_notify_cb_t = void (*)(pa_stream*, void*);
using pa_free_cb_t = void (*)(void*);

struct PulseApi {
  void* handle = nullptr;
  pa_mainloop* (*mainloop_new)() = nullptr;
  void (*mainloop_free)(pa_mainloop*) = nullptr;
  pa_mainloop_api* (*mainloop_get_api)(pa_mainloop*) = nullptr;
  int (*mainloop_iterate)(pa_mainloop*, int, int*) = nullptr;
  void (*mainloop_wakeup)(pa_mainloop*) = nullptr;
  pa_context* (*context_new)(pa_mainloop_api*, const char*) = nullptr;
  void (*context_unref)(pa_context*) = nullptr;
  int (*context_connect)(pa_context*, const char*, pa_context_flags_t, const pa_spawn_api*) = nullptr;
  void (*context_disconnect)(pa_context*) = nullptr;
  pa_context_state_t (*context_get_state)(const pa_context*) = nullptr;
  int (*context_errno)(const pa_context*) = nullptr;
  pa_operation* (*context_get_server_info)(pa_context*, pa_server_info_cb_t, void*) = nullptr;
  pa_operation* (*context_get_sink_info_list)(pa_context*, pa_sink_info_cb_t, void*) = nullptr;
  pa_operation* (*context_get_sink_info_by_name)(pa_context*, const char*, pa_sink_info_cb_t, void*) = nullptr;
  pa_operation* (*context_get_source_info_list)(pa_context*, pa_source_info_cb_t, void*) = nullptr;
  void (*operation_unref)(pa_operation*) = nullptr;
  void (*operation_cancel)(pa_operation*) = nullptr;
  pa_operation_state_t (*operation_get_state)(const pa_operation*) = nullptr;
  pa_stream* (*stream_new)(pa_context*, const char*, const pa_sample_spec*, const pa_channel_map*) = nullptr;
  void (*stream_unref)(pa_stream*) = nullptr;
  pa_stream_state_t (*stream_get_state)(const pa_stream*) = nullptr;
  int (*stream_is_suspended)(const pa_stream*) = nullptr;
  int (*stream_connect_record)(pa_stream*, const char*, const pa_buffer_attr*, unsigned int) = nullptr;
  int (*stream_connect_playback)(pa_stream*, const char*, const pa_buffer_attr*, unsigned int, const pa_cvolume*, pa_stream*) = nullptr;
  int (*stream_disconnect)(pa_stream*) = nullptr;
  int (*stream_peek)(pa_stream*, const void**, size_t*) = nullptr;
  int (*stream_drop)(pa_stream*) = nullptr;
  size_t (*stream_writable_size)(const pa_stream*) = nullptr;
  int (*stream_write)(pa_stream*, const void*, size_t, pa_free_cb_t, int64_t, pa_seek_mode_t) = nullptr;
  pa_operation* (*stream_cork)(pa_stream*, int, pa_stream_success_cb_t, void*) = nullptr;
  pa_operation* (*stream_flush)(pa_stream*, pa_stream_success_cb_t, void*) = nullptr;
  pa_operation* (*stream_drain)(pa_stream*, pa_stream_success_cb_t, void*) = nullptr;
  pa_operation* (*stream_update_timing_info)(pa_stream*, pa_stream_success_cb_t, void*) = nullptr;
  int (*stream_get_latency)(pa_stream*, pa_usec_t*, int*) = nullptr;
  const pa_buffer_attr* (*stream_get_buffer_attr)(pa_stream*) = nullptr;
  void (*stream_set_moved_callback)(pa_stream*, pa_stream_notify_cb_t, void*) = nullptr;
  void (*stream_set_underflow_callback)(pa_stream*, pa_stream_notify_cb_t, void*) = nullptr;

  template <typename Fn>
  void bind(Fn& target, const char* symbol) {
    void* sym = dlsym(handle, symbol);
    if (!sym) fail_throw(kErrFail, "Resolve libpulse.so.0 symbol");
    std::memcpy(&target, &sym, sizeof(target));
  }
};

const PulseApi& load_pulse() {
  static std::mutex mutex;
  static std::unique_ptr<PulseApi> cached;
  std::lock_guard<std::mutex> lock(mutex);
  if (cached) return *cached;

  void* lib = dlopen("libpulse.so.0", RTLD_NOW | RTLD_LOCAL);
  if (!lib) fail_throw(kErrNotFound, "Load libpulse.so.0 audio client library");

  auto api = std::make_unique<PulseApi>();
  api->handle = lib;
  try {
    api->bind(api->mainloop_new, "pa_mainloop_new");
    api->bind(api->mainloop_free, "pa_mainloop_free");
    api->bind(api->mainloop_get_api, "pa_mainloop_get_api");
    api->bind(api->mainloop_iterate, "pa_mainloop_iterate");
    api->bind(api->mainloop_wakeup, "pa_mainloop_wakeup");
    api->bind(api->context_new, "pa_context_new");
    api->bind(api->context_unref, "pa_context_unref");
    api->bind(api->context_connect, "pa_context_connect");
    api->bind(api->context_disconnect, "pa_context_disconnect");
    api->bind(api->context_get_state, "pa_context_get_state");
    api->bind(api->context_errno, "pa_context_errno");
    api->bind(api->context_get_server_info, "pa_context_get_server_info");
    api->bind(api->context_get_sink_info_list, "pa_context_get_sink_info_list");
    api->bind(api->context_get_sink_info_by_name, "pa_context_get_sink_info_by_name");
    api->bind(api->context_get_source_info_list, "pa_context_get_source_info_list");
    api->bind(api->operation_unref, "pa_operation_unref");
    api->bind(api->operation_cancel, "pa_operation_cancel");
    api->bind(api->operation_get_state, "pa_operation_get_state");
    api->bind(api->stream_new, "pa_stream_new");
    api->bind(api->stream_unref, "pa_stream_unref");
    api->bind(api->stream_get_state, "pa_stream_get_state");
    api->bind(api->stream_is_suspended, "pa_stream_is_suspended");
    api->bind(api->stream_connect_record, "pa_stream_connect_record");
    api->bind(api->stream_connect_playback, "pa_stream_connect_playback");
    api->bind(api->stream_disconnect, "pa_stream_disconnect");
    api->bind(api->stream_peek, "pa_stream_peek");
    api->bind(api->stream_drop, "pa_stream_drop");
    api->bind(api->stream_writable_size, "pa_stream_writable_size");
    api->bind(api->stream_write, "pa_stream_write");
    api->bind(api->stream_cork, "pa_stream_cork");
    api->bind(api->stream_flush, "pa_stream_flush");
    api->bind(api->stream_drain, "pa_stream_drain");
    api->bind(api->stream_update_timing_info, "pa_stream_update_timing_info");
    api->bind(api->stream_get_latency, "pa_stream_get_latency");
    api->bind(api->stream_get_buffer_attr, "pa_stream_get_buffer_attr");
    api->bind(api->stream_set_moved_callback, "pa_stream_set_moved_callback");
    api->bind(api->stream_set_underflow_callback, "pa_stream_set_underflow_callback");
  } catch (...) {
    dlclose(lib);
    throw;
  }
  cached = std::move(api);
  return *cached;
}

}  // namespace

struct mdw_cancel {
  std::atomic<bool> requested{false};
  std::mutex mutex;
  const PulseApi* pulse = nullptr;
  pa_mainloop* mainloop = nullptr;

  bool is_cancelled() const { return requested.load(std::memory_order_acquire); }
};

struct mdw_devices {
  std::vector<mdw_device> items;
};

struct mdw_recording {
  std::vector<uint8_t> bytes;
};

namespace {

struct CancelLoopBinding {
  mdw_cancel* cancel = nullptr;
  CancelLoopBinding(mdw_cancel* c, const PulseApi& api, pa_mainloop* loop) : cancel(c) {
    if (!cancel) return;
    std::lock_guard<std::mutex> lock(cancel->mutex);
    cancel->pulse = &api;
    cancel->mainloop = loop;
    if (cancel->is_cancelled()) api.mainloop_wakeup(loop);
  }
  ~CancelLoopBinding() {
    if (!cancel) return;
    std::lock_guard<std::mutex> lock(cancel->mutex);
    cancel->mainloop = nullptr;
    cancel->pulse = nullptr;
  }
  CancelLoopBinding(const CancelLoopBinding&) = delete;
  CancelLoopBinding& operator=(const CancelLoopBinding&) = delete;
};

struct PulseSession {
  const PulseApi& api;
  pa_mainloop* loop = nullptr;
  pa_context* context = nullptr;
  std::unique_ptr<CancelLoopBinding> binding;

  explicit PulseSession(const PulseApi& pulse, mdw_cancel* cancel = nullptr) : api(pulse) {
    loop = api.mainloop_new();
    require_state(loop != nullptr, "Create PulseAudio mainloop", kErrOutOfMemory);
    if (cancel) binding = std::make_unique<CancelLoopBinding>(cancel, api, loop);
    context = api.context_new(api.mainloop_get_api(loop), "MicDrop");
    if (!context) {
      binding.reset();
      api.mainloop_free(loop);
      loop = nullptr;
      fail_throw(kErrOutOfMemory, "Create PulseAudio context");
    }
    if (api.context_connect(context, nullptr, PA_CONTEXT_NOAUTOSPAWN, nullptr) < 0) {
      const int err = api.context_errno(context);
      teardown();
      fail_throw(err ? -err : kErrFail, "Connect to PipeWire/PulseAudio audio server");
    }
    while (true) {
      if (cancel && cancel->is_cancelled()) return;
      const auto state = api.context_get_state(context);
      if (state == PA_CONTEXT_READY) break;
      if (state == PA_CONTEXT_FAILED || state == PA_CONTEXT_TERMINATED) {
        const int err = api.context_errno(context);
        teardown();
        fail_throw(err ? -err : kErrFail, "Connect to PipeWire/PulseAudio audio server");
      }
      if (api.mainloop_iterate(loop, 1, nullptr) < 0) {
        teardown();
        fail_throw(kErrFail, "Iterate PulseAudio context handshake");
      }
    }
  }

  void teardown() {
    binding.reset();
    if (context) {
      api.context_disconnect(context);
      api.context_unref(context);
      context = nullptr;
    }
    if (loop) {
      api.mainloop_free(loop);
      loop = nullptr;
    }
  }

  ~PulseSession() { teardown(); }
  PulseSession(const PulseSession&) = delete;
  PulseSession& operator=(const PulseSession&) = delete;

  bool wait_operation(pa_operation* op, mdw_cancel* cancel, const char* label) {
    require_state(op != nullptr, label);
    struct OpGuard {
      const PulseApi& api;
      pa_operation* op;
      ~OpGuard() {
        if (op) api.operation_unref(op);
      }
    } guard{api, op};

    while (true) {
      if (cancel && cancel->is_cancelled()) {
        api.operation_cancel(op);
        return false;
      }
      const auto st = api.operation_get_state(op);
      if (st == PA_OPERATION_DONE) return true;
      if (st == PA_OPERATION_CANCELLED) fail_throw(kErrFail, label);
      const auto cst = api.context_get_state(context);
      if (cst != PA_CONTEXT_READY) {
        const int err = api.context_errno(context);
        fail_throw(err ? -err : kErrFail, label);
      }
      if (api.mainloop_iterate(loop, 1, nullptr) < 0) fail_throw(kErrFail, label);
    }
  }
};

struct StreamGuard {
  const PulseApi& api;
  pa_stream* stream = nullptr;
  ~StreamGuard() {
    if (stream) {
      api.stream_disconnect(stream);
      api.stream_unref(stream);
    }
  }
};

struct ServerDefaults {
  std::string sink;
  std::string source;
};

void on_server_info(pa_context*, const pa_server_info* info, void* userdata) {
  auto* out = static_cast<ServerDefaults*>(userdata);
  if (!info) return;
  if (info->default_sink_name) out->sink = info->default_sink_name;
  if (info->default_source_name) out->source = info->default_source_name;
}

ServerDefaults query_defaults(PulseSession& session, mdw_cancel* cancel) {
  ServerDefaults defaults;
  if (!session.wait_operation(
          session.api.context_get_server_info(session.context, on_server_info, &defaults),
          cancel, "Query default audio endpoints")) {
    return defaults;
  }
  return defaults;
}

struct SinkDetails {
  bool found = false;
  mdw_device device{};
  std::string monitor_source_name;
  pa_sample_spec spec{};
};

struct SinkListQuery {
  std::string default_sink;
  std::vector<mdw_device> devices;
  const char* error_label = nullptr;
};

void fill_device_entry(const char* id, const char* description, const std::string& default_name, mdw_device& out) {
  out = {};
  copy_checked_utf8(id, out.id, sizeof(out.id), "Endpoint ID exceeds diagnostic capacity");
  const char* label = (description && *description) ? description : id;
  copy_checked_utf8(label, out.name, sizeof(out.name), "Endpoint name exceeds diagnostic capacity");
  out.default_multimedia = (!default_name.empty() && default_name == id) ? 1 : 0;
}

void on_sink_list(pa_context*, const pa_sink_info* info, int eol, void* userdata) {
  auto* query = static_cast<SinkListQuery*>(userdata);
  if (eol > 0 || !info || query->error_label) return;
  try {
    mdw_device dev{};
    fill_device_entry(info->name, info->description, query->default_sink, dev);
    query->devices.push_back(dev);
  } catch (const Failure& f) {
    query->error_label = f.operation;
  } catch (...) {
    query->error_label = "Store output endpoint description";
  }
}

void on_single_sink(pa_context*, const pa_sink_info* info, int eol, void* userdata) {
  auto* out = static_cast<SinkDetails*>(userdata);
  if (eol > 0 || !info || out->found) return;
  try {
    out->device = {};
    copy_checked_utf8(info->name, out->device.id, sizeof(out->device.id), "Endpoint ID exceeds diagnostic capacity");
    const char* label = (info->description && *info->description) ? info->description : info->name;
    copy_checked_utf8(label, out->device.name, sizeof(out->device.name), "Endpoint name exceeds diagnostic capacity");
    if (info->monitor_source_name) out->monitor_source_name = info->monitor_source_name;
    out->spec = info->sample_spec;
    out->found = true;
  } catch (...) {
    out->found = false;
  }
}

struct SourceListQuery {
  std::string default_source;
  std::vector<mdw_device> devices;
  const char* error_label = nullptr;
};

void on_source_list(pa_context*, const pa_source_info* info, int eol, void* userdata) {
  auto* query = static_cast<SourceListQuery*>(userdata);
  if (eol > 0 || !info || query->error_label) return;
  // Exclude hardware sink monitor loopbacks when listing recording inputs, matching
  // how Linux conferencing/recording apps enumerate microphone endpoints; virtual
  // remap/duplex sources have monitor_of_sink == PA_INVALID_INDEX.
  if (info->monitor_of_sink != kPaInvalidIndex) return;
  try {
    mdw_device dev{};
    fill_device_entry(info->name, info->description, query->default_source, dev);
    query->devices.push_back(dev);
  } catch (const Failure& f) {
    query->error_label = f.operation;
  } catch (...) {
    query->error_label = "Store recording endpoint description";
  }
}

SinkDetails resolve_sink(
    PulseSession& session,
    const char* requested_id,
    mdw_cancel* cancel,
    bool allow_default,
    const char* missing_label = "Selected output endpoint was not found") {
  const auto defaults = query_defaults(session, cancel);
  if (cancel && cancel->is_cancelled()) return {};
  std::string target;
  if (requested_id && *requested_id) {
    require_arg(valid_utf8(requested_id, sizeof(mdw_device{}.id)), "Invalid or oversized UTF-8 endpoint ID");
    target = requested_id;
  } else {
    require_arg(allow_default, "Bridge requires an explicit render endpoint ID");
    require_state(!defaults.sink.empty(), "No default multimedia output sink is available", kErrNotFound);
    target = defaults.sink;
  }

  SinkDetails details;
  if (!session.wait_operation(
          session.api.context_get_sink_info_by_name(session.context, target.c_str(), on_single_sink, &details),
          cancel, missing_label)) {
    return {};
  }
  require_state(details.found, missing_label, kErrNotFound);
  details.device.default_multimedia = (!defaults.sink.empty() && defaults.sink == details.device.id) ? 1 : 0;
  return details;
}

uint32_t choose_capture_rate(uint32_t sink_rate) {
  if (sink_rate >= 8000 && sink_rate <= 384000 && (sink_rate % 100) == 0) return sink_rate;
  return 48000;
}

void describe_mix_format(const pa_sample_spec& spec, mdw_bridge_report& report) {
  report.mix_rate = (spec.rate >= 8000 && spec.rate <= 384000) ? spec.rate : 48000;
  report.mix_channels = (spec.channels >= 1 && spec.channels <= kPaChannelsMax) ? spec.channels : 2;
  report.mix_channel_mask = (report.mix_channels == 1) ? 4u : ((report.mix_channels == 2) ? 3u : 0u);
  switch (spec.format) {
    case PA_SAMPLE_FLOAT32LE:
    case PA_SAMPLE_FLOAT32BE:
      report.mix_bits = 32;
      report.mix_valid_bits = 32;
      report.mix_float = 1;
      break;
    case PA_SAMPLE_S32LE:
    case PA_SAMPLE_S32BE:
      report.mix_bits = 32;
      report.mix_valid_bits = 32;
      report.mix_float = 0;
      break;
    case PA_SAMPLE_S24_32LE:
    case PA_SAMPLE_S24_32BE:
      report.mix_bits = 32;
      report.mix_valid_bits = 24;
      report.mix_float = 0;
      break;
    case PA_SAMPLE_S24LE:
    case PA_SAMPLE_S24BE:
      report.mix_bits = 24;
      report.mix_valid_bits = 24;
      report.mix_float = 0;
      break;
    default:
      report.mix_bits = 16;
      report.mix_valid_bits = 16;
      report.mix_float = 0;
      break;
  }
}

void wait_stream_ready(PulseSession& session, pa_stream* stream, mdw_cancel* cancel, const char* label) {
  while (true) {
    if (cancel && cancel->is_cancelled()) return;
    const auto st = session.api.stream_get_state(stream);
    if (st == PA_STREAM_READY) return;
    if (st == PA_STREAM_FAILED || st == PA_STREAM_TERMINATED) {
      const int err = session.api.context_errno(session.context);
      fail_throw(err ? -err : kErrFail, label);
    }
    if (session.api.mainloop_iterate(session.loop, 1, nullptr) < 0) fail_throw(kErrFail, label);
  }
}

void on_stream_moved(pa_stream*, void* userdata) {
  auto* moved = static_cast<std::atomic<bool>*>(userdata);
  moved->store(true, std::memory_order_release);
}

void on_stream_underflow(pa_stream*, void* userdata) {
  auto* count = static_cast<std::atomic<uint64_t>*>(userdata);
  count->fetch_add(1, std::memory_order_relaxed);
}

void on_stream_op_done(pa_stream*, int, void*) {}

int run_capture_stream(
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
    const auto& api = load_pulse();
    PulseSession session(api, cancel);
    if (cancel->is_cancelled()) return 2;

    const auto sink = resolve_sink(session, endpoint_id, cancel, true);
    if (cancel->is_cancelled()) return 2;
    require_state(!sink.monitor_source_name.empty(), "Selected output sink exposes no loopback monitor source");

    const uint32_t sample_rate = choose_capture_rate(sink.spec.rate);
    constexpr uint32_t channels = 2;
    constexpr size_t frame_bytes = channels * sizeof(float);
    const uint32_t period_frames = sample_rate / 100;  // 10 ms packets

    mdw_report local_report{};
    mdw_report& report = out_report ? *out_report : local_report;
    report = {};
    report.device = sink.device;
    report.sample_rate = sample_rate;
    report.channels = channels;
    report.container_bits = 32;
    report.valid_bits = 32;
    report.channel_mask = 3;
    report.float_source = 1;
    report.buffer_frames = period_frames * 4;
    report.default_period_100ns = 100000;  // 10 ms in 100ns units
    report.minimum_period_100ns = 50000;   // 5 ms in 100ns units

    std::unique_ptr<mdw_recording> recording;
    size_t recording_capacity = 0;
    if (timed && store_pcm) {
      const uint64_t expected_frames = (static_cast<uint64_t>(sample_rate) * (duration_ms + 500)) / 1000;
      const uint64_t expected_bytes = expected_frames * channels * sizeof(int16_t);
      recording_capacity = static_cast<size_t>(std::min<uint64_t>(
          kMaxRecordingBytes, std::max<uint64_t>(expected_bytes, 65536u)));
      recording = std::make_unique<mdw_recording>();
      recording->bytes.reserve(recording_capacity);
    }

    if (format_sink) {
      require_state(format_sink(sink_context, &report) == 0, "Configure live audio format sink");
    }

    pa_sample_spec spec{PA_SAMPLE_FLOAT32LE, sample_rate, static_cast<uint8_t>(channels)};
    StreamGuard stream{api, api.stream_new(session.context, "MicDrop Desktop Capture", &spec, nullptr)};
    require_state(stream.stream != nullptr, "Create desktop loopback capture stream", kErrOutOfMemory);

    std::atomic<bool> moved{false};
    api.stream_set_moved_callback(stream.stream, on_stream_moved, &moved);

    pa_buffer_attr attr{};
    attr.maxlength = static_cast<uint32_t>(period_frames * 8 * frame_bytes);
    attr.tlength = 0xFFFFFFFFu;
    attr.prebuf = 0xFFFFFFFFu;
    attr.minreq = 0xFFFFFFFFu;
    attr.fragsize = static_cast<uint32_t>(period_frames * frame_bytes);

    const unsigned int flags =
        PA_STREAM_DONT_MOVE | PA_STREAM_ADJUST_LATENCY | PA_STREAM_FAIL_ON_SUSPEND;
    require_state(
        api.stream_connect_record(stream.stream, sink.monitor_source_name.c_str(), &attr, flags) >= 0,
        "Connect desktop loopback monitor stream");

    wait_stream_ready(session, stream.stream, cancel, "Start desktop loopback monitor stream");
    if (cancel->is_cancelled()) return 2;

    if (const auto* negotiated = api.stream_get_buffer_attr(stream.stream)) {
      if (negotiated->fragsize >= frame_bytes) {
        report.buffer_frames = static_cast<uint32_t>(negotiated->fragsize / frame_bytes);
      }
    }

    std::vector<float> aligned_samples(static_cast<size_t>(sample_rate) * channels);
    std::array<double, MDW_MAX_CHANNELS> sum_squares{};
    micdrop::pcm::Positions positions;
    bool pending_discontinuity = false;

    const auto start = std::chrono::steady_clock::now();
    const auto stop_at = start + std::chrono::milliseconds(duration_ms);

    while (true) {
      if (cancel->is_cancelled()) return 2;
      if (moved.load(std::memory_order_acquire) || api.stream_is_suspended(stream.stream) > 0) {
        fail_throw(kErrFail, "Pinned desktop output endpoint became unavailable");
      }
      const auto st = api.stream_get_state(stream.stream);
      if (st != PA_STREAM_READY) fail_throw(kErrFail, "Desktop loopback monitor stream terminated");

      while (true) {
        const void* raw = nullptr;
        size_t nbytes = 0;
        require_state(api.stream_peek(stream.stream, &raw, &nbytes) >= 0, "Read desktop loopback packet");
        if (nbytes == 0) break;

        if (!raw) {
          // Buffer hole reported by PulseAudio/PipeWire.
          require_state(api.stream_drop(stream.stream) >= 0, "Drop desktop loopback gap");
          ++report.discontinuities;
          if (report.packets == 0) report.first_packet_discontinuity = 1;
          pending_discontinuity = true;
          continue;
        }

        const uint32_t frames = static_cast<uint32_t>(nbytes / frame_bytes);
        if (frames == 0) {
          require_state(api.stream_drop(stream.stream) >= 0, "Drop partial loopback bytes");
          continue;
        }

        const size_t sample_count = static_cast<size_t>(frames) * channels;
        if (sample_count > aligned_samples.size()) {
          // Only possible if a server hands an unusually large multi-second chunk; clamp iteration safely.
          fail_throw(kErrFail, "Loopback packet exceeds bounded capture buffer");
        }
        std::memcpy(aligned_samples.data(), raw, sample_count * sizeof(float));
        require_state(api.stream_drop(stream.stream) >= 0, "Release desktop loopback packet");

        uint32_t pkt_flags = 0;
        if (pending_discontinuity) {
          pkt_flags |= 1u;  // Discontinuity
          pending_discontinuity = false;
        }

        const uint64_t qpc = monotonic_100ns();
        positions.add(report.frames, qpc, frames, false);

        if (report.packets == 0 || frames < report.min_packet_frames) report.min_packet_frames = frames;
        if (frames > report.max_packet_frames) report.max_packet_frames = frames;
        ++report.packets;
        report.frames += frames;

        if (timed) {
          for (uint32_t f = 0; f < frames; ++f) {
            for (uint32_t c = 0; c < channels; ++c) {
              const float v = aligned_samples[static_cast<size_t>(f) * channels + c];
              if (!std::isfinite(v)) {
                ++report.nonfinite_samples;
                continue;
              }
              const double abs_v = std::abs(static_cast<double>(v));
              if (abs_v > 1.0) ++report.clipped_samples;
              if (abs_v > report.peak[c]) report.peak[c] = abs_v;
              sum_squares[c] += static_cast<double>(v) * static_cast<double>(v);
            }
          }
          if (store_pcm) {
            const size_t pcm_bytes = sample_count * sizeof(int16_t);
            require_state(
                recording->bytes.size() + pcm_bytes <= kMaxRecordingBytes,
                "Diagnostic PCM recording exceeded the 64 MiB cap");
            require_state(
                recording->bytes.size() + pcm_bytes <= recording_capacity,
                "Diagnostic PCM recording exceeded preallocated capacity");
            for (size_t i = 0; i < sample_count; ++i) {
              const int16_t s16 = micdrop::pcm::to_pcm16(aligned_samples[i]);
              const uint16_t u16 = static_cast<uint16_t>(s16);
              recording->bytes.push_back(static_cast<uint8_t>(u16 & 0xFFu));
              recording->bytes.push_back(static_cast<uint8_t>((u16 >> 8) & 0xFFu));
            }
          }
        }

        if (packet_sink) {
          require_state(
              packet_sink(sink_context, aligned_samples.data(), frames, pkt_flags) == 0,
              "Deliver desktop loopback packet");
        }
      }

      if (timed && std::chrono::steady_clock::now() >= stop_at) break;
      const int timeout_ms = timed
          ? static_cast<int>(std::clamp<int64_t>(
                std::chrono::duration_cast<std::chrono::milliseconds>(
                    stop_at - std::chrono::steady_clock::now())
                    .count(),
                1, 20))
          : 50;
      require_state(api.mainloop_iterate(session.loop, 0, nullptr) >= 0, "Service loopback events");
      // Poll briefly using mainloop_iterate when non-timed, or bounded sleep/iterate when timed.
      if (!timed) {
        if (api.mainloop_iterate(session.loop, 1, nullptr) < 0) {
          fail_throw(kErrFail, "Wait for desktop loopback audio");
        }
      } else {
        std::this_thread::sleep_for(std::chrono::milliseconds(std::min(timeout_ms, 5)));
        require_state(api.mainloop_iterate(session.loop, 0, nullptr) >= 0, "Drain loopback events");
      }
    }

    report.elapsed_ms =
        std::chrono::duration<double, std::milli>(std::chrono::steady_clock::now() - start).count();
    report.position_gap_frames = positions.gaps;
    report.position_regressions = positions.regressions;
    report.valid_timestamps = positions.valid;
    report.first_device_frame = positions.first_frame;
    report.last_device_frame = positions.last_frame;
    report.first_qpc_100ns = positions.first_qpc;
    report.last_qpc_100ns = positions.last_qpc;
    if (report.frames > 0) {
      for (uint32_t c = 0; c < channels; ++c) {
        report.rms[c] = std::sqrt(sum_squares[c] / static_cast<double>(report.frames));
      }
    }
    if (timed && store_pcm && out_recording) {
      *out_recording = recording.release();
    }
    return 0;
  } catch (const Failure& f) {
    return fail_out(error, f.code, f.operation);
  } catch (const std::bad_alloc&) {
    return fail_out(error, kErrOutOfMemory, "Allocate desktop capture state");
  } catch (...) {
    return fail_out(error, kErrFail, "Unexpected Linux desktop capture failure");
  }
}

}  // namespace

extern "C" mdw_cancel* mdw_cancel_create(void) {
  return new (std::nothrow) mdw_cancel();
}

extern "C" void mdw_cancel_request(mdw_cancel* cancel) {
  if (!cancel) return;
  cancel->requested.store(true, std::memory_order_release);
  std::lock_guard<std::mutex> lock(cancel->mutex);
  if (cancel->mainloop && cancel->pulse) {
    cancel->pulse->mainloop_wakeup(cancel->mainloop);
  }
}

extern "C" void mdw_cancel_free(mdw_cancel* cancel) {
  delete cancel;
}

extern "C" int mdw_devices_list(mdw_devices** out, mdw_error* error) {
  if (!out) return fail_out(error, kErrInvalidArg, "Output device list pointer is null");
  *out = nullptr;
  if (error) *error = {};
  try {
    const auto& api = load_pulse();
    PulseSession session(api);
    const auto defaults = query_defaults(session, nullptr);
    SinkListQuery query{defaults.sink, {}, nullptr};
    session.wait_operation(
        api.context_get_sink_info_list(session.context, on_sink_list, &query),
        nullptr, "Enumerate output audio sinks");
    if (query.error_label) fail_throw(kErrInvalidArg, query.error_label);
    auto result = std::make_unique<mdw_devices>();
    result->items = std::move(query.devices);
    *out = result.release();
    return 0;
  } catch (const Failure& f) {
    return fail_out(error, f.code, f.operation);
  } catch (const std::bad_alloc&) {
    return fail_out(error, kErrOutOfMemory, "Allocate output device list");
  } catch (...) {
    return fail_out(error, kErrFail, "Unexpected output device enumeration failure");
  }
}

extern "C" int mdw_input_devices_list(mdw_devices** out, mdw_error* error) {
  if (!out) return fail_out(error, kErrInvalidArg, "Input device list pointer is null");
  *out = nullptr;
  if (error) *error = {};
  try {
    const auto& api = load_pulse();
    PulseSession session(api);
    const auto defaults = query_defaults(session, nullptr);
    SourceListQuery query{defaults.source, {}, nullptr};
    session.wait_operation(
        api.context_get_source_info_list(session.context, on_source_list, &query),
        nullptr, "Enumerate recording audio sources");
    if (query.error_label) fail_throw(kErrInvalidArg, query.error_label);
    auto result = std::make_unique<mdw_devices>();
    result->items = std::move(query.devices);
    *out = result.release();
    return 0;
  } catch (const Failure& f) {
    return fail_out(error, f.code, f.operation);
  } catch (const std::bad_alloc&) {
    return fail_out(error, kErrOutOfMemory, "Allocate input device list");
  } catch (...) {
    return fail_out(error, kErrFail, "Unexpected input device enumeration failure");
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
  return run_capture_stream(
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
  return run_capture_stream(
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
    const auto& api = load_pulse();
    PulseSession session(api, cancel);
    if (cancel->is_cancelled()) return 2;

    const auto sink = resolve_sink(
        session, render_endpoint_id, cancel, false,
        "Open selected bridge endpoint; rerun bridge-devices");
    if (cancel->is_cancelled()) return 2;

    report->device = sink.device;
    describe_mix_format(sink.spec, *report);
    report->buffer_frames = kBridgeBufferFrames;
    report->default_period_100ns = 100000;

    constexpr size_t frame_bytes = micdrop::bridge_signal::frame_bytes;
    pa_sample_spec spec{PA_SAMPLE_FLOAT32LE, micdrop::bridge_signal::rate,
                        static_cast<uint8_t>(micdrop::bridge_signal::channels)};
    StreamGuard stream{api, api.stream_new(session.context, "MicDrop Bridge Check", &spec, nullptr)};
    require_state(stream.stream != nullptr, "Create bridge playback stream", kErrOutOfMemory);

    std::atomic<bool> moved{false};
    std::atomic<uint64_t> underflows{0};
    api.stream_set_moved_callback(stream.stream, on_stream_moved, &moved);
    api.stream_set_underflow_callback(stream.stream, on_stream_underflow, &underflows);

    pa_buffer_attr attr{};
    attr.maxlength = static_cast<uint32_t>(kBridgeBufferFrames * 2 * frame_bytes);
    attr.tlength = static_cast<uint32_t>(kBridgeBufferFrames * frame_bytes);
    attr.prebuf = static_cast<uint32_t>((kBridgeBufferFrames / 2) * frame_bytes);
    attr.minreq = static_cast<uint32_t>((kBridgeBufferFrames / 2) * frame_bytes);
    attr.fragsize = 0xFFFFFFFFu;

    const unsigned int flags =
        PA_STREAM_DONT_MOVE | PA_STREAM_ADJUST_LATENCY | PA_STREAM_FAIL_ON_SUSPEND |
        PA_STREAM_AUTO_TIMING_UPDATE | PA_STREAM_INTERPOLATE_TIMING;
    require_state(
        api.stream_connect_playback(stream.stream, sink.device.id, &attr, flags, nullptr, nullptr) >= 0,
        "Connect bridge playback stream");

    wait_stream_ready(session, stream.stream, cancel, "Start bridge playback stream");
    if (cancel->is_cancelled()) return 2;

    const uint64_t total_frames =
        (static_cast<uint64_t>(micdrop::bridge_signal::rate) * duration_ms) / 1000;
    std::array<uint8_t, kBridgeBufferFrames * frame_bytes> chunk{};
    const auto start = std::chrono::steady_clock::now();
    const auto deadline = start + std::chrono::milliseconds(duration_ms) + std::chrono::seconds(5);

    while (report->frames_written < total_frames) {
      if (cancel->is_cancelled()) return 2;
      if (std::chrono::steady_clock::now() >= deadline) {
        fail_throw(kErrTimeout, "Selected bridge endpoint failed to finish within its deadline");
      }
      if (moved.load(std::memory_order_acquire) || api.stream_is_suspended(stream.stream) > 0 ||
          api.stream_get_state(stream.stream) != PA_STREAM_READY) {
        fail_throw(kErrFail, "Selected bridge endpoint became unavailable");
      }

      const size_t writable_bytes = api.stream_writable_size(stream.stream);
      require_state(writable_bytes != static_cast<size_t>(-1), "Query bridge playback queue");
      const uint32_t writable_frames = static_cast<uint32_t>(writable_bytes / frame_bytes);
      const uint32_t padding =
          (writable_frames < report->buffer_frames) ? (report->buffer_frames - writable_frames) : 0;
      report->maximum_padding_frames = std::max(report->maximum_padding_frames, padding);

      if (writable_frames > 0) {
        const uint32_t to_write = static_cast<uint32_t>(std::min<uint64_t>(
            std::min<uint32_t>(writable_frames, kBridgeBufferFrames),
            total_frames - report->frames_written));
        require_state(
            micdrop::bridge_signal::fill(chunk.data(), chunk.size(), report->frames_written, to_write),
            "Generate bridge verification signal");
        require_state(
            api.stream_write(stream.stream, chunk.data(), to_write * frame_bytes, nullptr, 0, PA_SEEK_RELATIVE) >= 0,
            "Write bridge verification audio");
        report->frames_written += to_write;
        ++report->writes;
      } else {
        require_state(api.mainloop_iterate(session.loop, 1, nullptr) >= 0, "Wait for bridge playback");
      }
      require_state(api.mainloop_iterate(session.loop, 0, nullptr) >= 0, "Service bridge playback");
    }

    pa_usec_t latency_usec = 0;
    int negative = 0;
    if (api.stream_get_latency(stream.stream, &latency_usec, &negative) == 0 && !negative) {
      report->stream_latency_100ns = static_cast<int64_t>(latency_usec * 10);
    }

    if (!session.wait_operation(
            api.stream_drain(stream.stream, on_stream_op_done, nullptr),
            cancel, "Drain bridge playback stream")) {
      return 2;
    }

    report->empty_buffer_events = underflows.load(std::memory_order_relaxed);
    report->elapsed_ms =
        std::chrono::duration<double, std::milli>(std::chrono::steady_clock::now() - start).count();
    return 0;
  } catch (const Failure& f) {
    return fail_out(error, f.code, f.operation);
  } catch (const std::bad_alloc&) {
    return fail_out(error, kErrOutOfMemory, "Allocate bridge setup");
  } catch (...) {
    return fail_out(error, kErrFail, "Unexpected native bridge failure");
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
    const PulseApi* api_ptr = nullptr;
    std::unique_ptr<PulseSession> session_ptr;
    SinkDetails sink;
    try {
      api_ptr = &load_pulse();
      session_ptr = std::make_unique<PulseSession>(*api_ptr, cancel);
      if (cancel->is_cancelled()) return 2;
      sink = resolve_sink(
          *session_ptr, render_endpoint_id, cancel, false,
          "Open selected microphone cable; rerun bridge-devices");
    } catch (const Failure& f) {
      fail_throw(f.code ? f.code : kErrNotFound, "Open selected microphone cable; rerun bridge-devices");
    }
    if (cancel->is_cancelled()) return 2;
    const auto& api = *api_ptr;
    auto& session = *session_ptr;

    mdw_bridge_report report{};
    report.device = sink.device;
    describe_mix_format(sink.spec, report);
    report.buffer_frames = kBridgeBufferFrames;
    report.default_period_100ns = 100000;

    constexpr size_t frame_bytes = micdrop::bridge_signal::frame_bytes;
    pa_sample_spec spec{PA_SAMPLE_FLOAT32LE, micdrop::bridge_signal::rate,
                        static_cast<uint8_t>(micdrop::bridge_signal::channels)};
    StreamGuard stream{api, api.stream_new(session.context, "MicDrop Microphone Return", &spec, nullptr)};
    require_state(stream.stream != nullptr, "Create microphone cable stream", kErrOutOfMemory);

    std::atomic<bool> moved{false};
    std::atomic<uint64_t> underflows{0};
    api.stream_set_moved_callback(stream.stream, on_stream_moved, &moved);
    api.stream_set_underflow_callback(stream.stream, on_stream_underflow, &underflows);

    pa_buffer_attr attr{};
    attr.maxlength = static_cast<uint32_t>(kBridgeBufferFrames * 2 * frame_bytes);
    attr.tlength = static_cast<uint32_t>(kBridgeBufferFrames * frame_bytes);
    attr.prebuf = static_cast<uint32_t>((kBridgeBufferFrames / 2) * frame_bytes);
    attr.minreq = static_cast<uint32_t>((kBridgeBufferFrames / 2) * frame_bytes);
    attr.fragsize = 0xFFFFFFFFu;

    const unsigned int flags =
        PA_STREAM_START_CORKED | PA_STREAM_DONT_MOVE | PA_STREAM_ADJUST_LATENCY |
        PA_STREAM_FAIL_ON_SUSPEND | PA_STREAM_AUTO_TIMING_UPDATE | PA_STREAM_INTERPOLATE_TIMING;
    require_state(
        api.stream_connect_playback(stream.stream, sink.device.id, &attr, flags, nullptr, nullptr) >= 0,
        "Initialize microphone cable renderer");

    wait_stream_ready(session, stream.stream, cancel, "Start microphone cable renderer");
    if (cancel->is_cancelled()) return 2;

    std::array<float, kBridgeBufferFrames * 2> scratch{};
    auto write_frames = [&](uint32_t frames) {
      uint32_t remaining = frames;
      while (remaining > 0) {
        const uint32_t step = std::min<uint32_t>(remaining, kBridgeBufferFrames);
        require_state(pull(context, scratch.data(), step) == 0, "Pull decoded microphone audio");
        require_state(
            api.stream_write(stream.stream, scratch.data(), step * frame_bytes, nullptr, 0, PA_SEEK_RELATIVE) >= 0,
            "Submit microphone cable buffer");
        report.frames_written += step;
        ++report.writes;
        remaining -= step;
      }
    };

    uint64_t revision = gate(context);
    write_frames(report.buffer_frames);
    if (!session.wait_operation(
            api.stream_cork(stream.stream, 0, on_stream_op_done, nullptr),
            cancel, "Uncork microphone cable renderer")) {
      return 2;
    }
    applied(context, revision);
    status(context, &report);

    auto last_progress = std::chrono::steady_clock::now();
    while (true) {
      if (cancel->is_cancelled()) return 2;
      if (moved.load(std::memory_order_acquire) || api.stream_is_suspended(stream.stream) > 0 ||
          api.stream_get_state(stream.stream) != PA_STREAM_READY) {
        fail_throw(kErrFail, "Selected microphone cable became unavailable");
      }

      const uint64_t current = gate(context);
      if (current != revision) {
        if (!session.wait_operation(
                api.stream_cork(stream.stream, 1, on_stream_op_done, nullptr),
                cancel, "Stop microphone cable for mute change")) {
          return 2;
        }
        if (!session.wait_operation(
                api.stream_flush(stream.stream, on_stream_op_done, nullptr),
                cancel, "Discard queued microphone audio")) {
          return 2;
        }
        revision = current;
        write_frames(report.buffer_frames);
        if (!session.wait_operation(
                api.stream_cork(stream.stream, 0, on_stream_op_done, nullptr),
                cancel, "Restart microphone cable after mute change")) {
          return 2;
        }
        applied(context, revision);
        last_progress = std::chrono::steady_clock::now();
      }

      const size_t writable_bytes = api.stream_writable_size(stream.stream);
      require_state(writable_bytes != static_cast<size_t>(-1), "Read microphone cable queue");
      const uint32_t writable_frames = static_cast<uint32_t>(writable_bytes / frame_bytes);
      const uint32_t padding =
          (writable_frames < report.buffer_frames) ? (report.buffer_frames - writable_frames) : 0;
      report.maximum_padding_frames = std::max(report.maximum_padding_frames, padding);

      if (writable_frames > 0) {
        write_frames(std::min<uint32_t>(writable_frames, kBridgeBufferFrames));
        last_progress = std::chrono::steady_clock::now();
      } else if (std::chrono::steady_clock::now() - last_progress > std::chrono::seconds(5)) {
        fail_throw(kErrTimeout, "Microphone cable stopped consuming audio");
      }

      pa_usec_t latency_usec = 0;
      int negative = 0;
      if (api.stream_get_latency(stream.stream, &latency_usec, &negative) == 0 && !negative) {
        report.stream_latency_100ns = static_cast<int64_t>(latency_usec * 10);
      }
      report.empty_buffer_events = underflows.load(std::memory_order_relaxed);
      status(context, &report);

      if (writable_frames == 0) {
        require_state(api.mainloop_iterate(session.loop, 1, nullptr) >= 0, "Wait for microphone cable renderer");
      } else {
        require_state(api.mainloop_iterate(session.loop, 0, nullptr) >= 0, "Service microphone cable renderer");
      }
    }
  } catch (const Failure& f) {
    return fail_out(error, f.code, f.operation);
  } catch (const std::bad_alloc&) {
    return fail_out(error, kErrOutOfMemory, "Allocate microphone cable renderer");
  } catch (...) {
    return fail_out(error, kErrFail, "Unexpected microphone cable failure");
  }
}
