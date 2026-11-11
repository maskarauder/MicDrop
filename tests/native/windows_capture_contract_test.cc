#include "capture.h"
#include "bridge.h"
#include <cstdio>

static int pull(void*, float*, uint32_t) { return 1; }
static uint64_t gate(void*) { return 0; }
static void applied(void*, uint64_t) {}
static void status(void*, const mdw_bridge_report*) {}

int main() {
  mdw_error error{};
  mdw_report report{};
  mdw_recording* recording = nullptr;
  auto* cancel = mdw_cancel_create();
  if (!cancel) return 1;
  bool ok = mdw_capture_run("", 0, 0, cancel, &report, &recording, &error) == 1 && !recording;
  ok = ok && mdw_capture_run("", 100, 0, cancel, nullptr, &recording, &error) == 1;
  ok = ok && mdw_devices_list(nullptr, &error) == 1;
  mdw_bridge_report bridge{};
  ok = ok && mdw_input_devices_list(nullptr, &error) == 1;
  ok = ok && mdw_bridge_check("", 100, cancel, &bridge, &error) == 1;
  ok = ok && mdw_bridge_check("id", 0, cancel, &bridge, &error) == 1;
  ok = ok && mdw_bridge_check("id", 100, cancel, nullptr, &error) == 1;
  ok = ok && mdw_bridge_live("", cancel, &bridge, pull, gate, applied, status, &error) == 1;
  ok = ok && mdw_bridge_live("id", cancel, &bridge, nullptr, gate, applied, status, &error) == 1;
  mdw_cancel_request(cancel);
  // Must stop BEFORE opening any audio device, including on headless CI workers.
  ok = ok && mdw_capture_run("", 100, 0, cancel, &report, &recording, &error) == 2 && !recording;
  ok = ok && mdw_bridge_check("id", 100, cancel, &bridge, &error) == 2;
  ok = ok && mdw_bridge_live("id", cancel, &bridge, pull, gate, applied, status, &error) == 2;
  mdw_cancel_free(cancel);
  mdw_recording_free(nullptr);
  mdw_devices_free(nullptr);
  ok = ok && mdw_recording_size(nullptr) == 0 && mdw_recording_data(nullptr) == nullptr;
  ok = ok && mdw_devices_count(nullptr) == 0 && mdw_devices_get(nullptr, 0) == nullptr;
  if (!ok) std::fprintf(stderr, "Windows capture ownership/argument contract failed\n");
  return ok ? 0 : 1;
}
