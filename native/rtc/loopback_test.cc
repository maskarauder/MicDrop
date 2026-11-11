#include "capi.h"
#include <chrono>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <memory>
#include <string>
#include <thread>

using Peer = std::unique_ptr<mdr_peer, decltype(&mdr_destroy)>;
static uint64_t Number(const char* json, const char* key) {
  const std::string needle = std::string("\"") + key + "\":";
  const char* value = std::strstr(json, needle.c_str());
  return value ? std::strtoull(value + needle.size(), nullptr, 10) : 0;
}
static std::string IceUser(const char* sdp) {
  const char* first = std::strstr(sdp, "a=ice-ufrag:");
  if (!first) return {};
  const char* end = std::strstr(first, "\r\n");
  return end ? std::string(first, end) : std::string();
}
static int Session() {
  char error[512]{}, offer[65537]{}, answer[65537]{}, status[4096]{};
  mdr_peer* raw = nullptr;
  if (mdr_create_configured(1, "", 2, 0, &raw, error, sizeof(error)) != 1 || raw != nullptr ||
      mdr_create_duplex_configured(1, "", "chosen-cable", -1, 0, &raw, error, sizeof(error)) != 1 || raw != nullptr) return 1;
  if (mdr_create(1, "", &raw, error, sizeof(error))) { std::puts(error); return 1; }
  Peer sender(raw, mdr_destroy);
  if (mdr_create(2, "", &raw, error, sizeof(error))) { std::puts(error); return 1; }
  Peer receiver(raw, mdr_destroy);
  if (mdr_offer(sender.get(), offer, sizeof(offer), error, sizeof(error))) { std::puts(error); return 1; }
  if (mdr_status(sender.get(), status, sizeof(status)) || Number(status, "pcm_frames_sent") != 0) {
    std::puts("Audio was sent before authorization"); return 1;
  }
  if (mdr_test_accept(receiver.get(), offer, answer, sizeof(answer), error, sizeof(error)) ||
      mdr_answer(sender.get(), answer, error, sizeof(error))) { std::puts(error); return 1; }
  std::puts("Stock receiver rejected modified codec capabilities and accepted a stereo local answer");
  // Only report structure; SDP contains local addresses and credentials.
  std::printf("offer_candidates=%d answer_candidates=%d rejected_audio=%d receiving_audio=%d\n",
      std::strstr(offer, "a=candidate:") != nullptr, std::strstr(answer, "a=candidate:") != nullptr,
      std::strstr(answer, "m=audio 0 ") != nullptr, std::strstr(answer, "a=recvonly") != nullptr);
  for (int attempt = 0; attempt < 100; ++attempt) {
    std::this_thread::sleep_for(std::chrono::milliseconds(100));
    if (mdr_status(receiver.get(), status, sizeof(status))) return 1;
    if (Number(status, "decoded_distinct_stereo_frames") > 24000) {
      if (!std::strstr(status, "\"media_transport\":{") ||
          !std::strstr(status, "\"relay_protocol\":\"not_applicable\"")) return 1;
      std::puts(status);
      if (mdr_status(sender.get(), status, sizeof(status))) return 1;
      if (!std::strstr(status, "\"media_transport\":{") ||
          !std::strstr(status, "\"relay_protocol\":\"not_applicable\"")) return 1;
      std::puts(status);
      // A 10 ms Opus packet consumes 480 input frames. Allow initial transport
      // startup to discard frames; a 20 ms encoder cannot meet this ratio.
      const auto frames = Number(status, "pcm_frames_sent"), packets = Number(status, "packets_sent");
      if (Number(status, "encoder_channels") != 2 || Number(status, "encoder_packet_ms_at_creation") != 10 ||
          Number(status, "encoder_bitrate_bps_at_creation") != 128000) return 1;
      if (packets < 10 || packets * 480 < frames * 7 / 10 || !std::strstr(status, "\"opus\":true")) return 1;
      return 0;
    }
  }
  std::puts(status);
  if (!mdr_status(sender.get(), status, sizeof(status))) std::puts(status);
  std::puts("No distinct stereo PCM decoded within ten seconds"); return 1;
}

// The persistent host repeatedly creates and destroys native peers. Verify
// process-global WebRTC state remains usable after complete media teardown.
static int ReturnSession() {
  char error[512]{}, offer[65537]{}, answer[65537]{}, status[4096]{};
  mdr_peer* raw = nullptr;
  if (mdr_create(2, "", &raw, error, sizeof(error))) { std::puts(error); return 1; }
  Peer receiver(raw, mdr_destroy);
  if (mdr_create(4, "", &raw, error, sizeof(error))) { std::puts(error); return 1; }
  Peer sender(raw, mdr_destroy);
  if (mdr_offer(receiver.get(), offer, sizeof(offer), error, sizeof(error))) {
    std::puts(error); return 1;
  }
  if (!std::strstr(offer, "a=recvonly")) { std::puts("Return offer is not receive-only"); return 1; }
  if (mdr_test_send_accept(sender.get(), offer, answer, sizeof(answer), error, sizeof(error))) {
    std::puts(error); return 1;
  }
  if (!std::strstr(answer, "a=sendonly")) {
    std::printf("Return answer is not send-only: rejected=%d inactive=%d receive=%d\n",
        std::strstr(answer, "m=audio 0 ") != nullptr, std::strstr(answer, "a=inactive") != nullptr,
        std::strstr(answer, "a=recvonly") != nullptr);
    return 1;
  }
  if (mdr_answer(receiver.get(), answer, error, sizeof(error))) {
    std::puts(error); return 1;
  }
  for (int i = 0; i < 100; ++i) {
    std::this_thread::sleep_for(std::chrono::milliseconds(100));
    if (mdr_status(receiver.get(), status, sizeof(status))) return 1;
    if (Number(status, "decoded_nonzero_frames") > 24000 && Number(status, "return_packets_received") > 10 &&
        std::strstr(status, "\"opus\":true")) {
      std::puts("Receive-only host offer decoded authenticated-peer answer audio"); return 0;
    }
  }
  std::puts(status); return 1;
}

static int DuplexSession() {
  char error[512]{}, offer[65537]{}, answer[65537]{}, host_status[4096]{}, phone_status[4096]{};
  mdr_peer* raw = nullptr;
  if (mdr_create(7, "", &raw, error, sizeof(error))) { std::puts(error); return 1; }
  Peer host(raw, mdr_destroy);
  if (mdr_create(4, "", &raw, error, sizeof(error))) return 1;
  Peer phone(raw, mdr_destroy);
  if (mdr_offer(host.get(), offer, sizeof(offer), error, sizeof(error)) || !std::strstr(offer, "a=sendrecv") ||
      mdr_status(host.get(), host_status, sizeof(host_status)) || Number(host_status, "pcm_frames_sent") != 0 ||
      Number(host_status, "bridge_nonzero_frames_provided") != 0 ||
      mdr_microphone_mute(host.get(), 0, error, sizeof(error)) != 1) return 1;
  if (mdr_test_duplex_accept(phone.get(), offer, answer, sizeof(answer), error, sizeof(error)) ||
      !std::strstr(answer, "a=sendrecv") || mdr_answer(host.get(), answer, error, sizeof(error))) {
    std::puts(error); return 1;
  }
  auto ready = [&] {
    for (int i = 0; i < 100; ++i) {
      std::this_thread::sleep_for(std::chrono::milliseconds(100));
      if (mdr_status(host.get(), host_status, sizeof(host_status)) ||
          mdr_status(phone.get(), phone_status, sizeof(phone_status))) return false;
      if (Number(host_status, "decoded_nonzero_frames") > 24000 && Number(host_status, "return_packets_received") > 10 &&
          Number(phone_status, "decoded_distinct_stereo_frames") > 24000) return true;
    }
    return false;
  };
  if (!ready() || Number(host_status, "bridge_nonzero_frames_provided") != 0 ||
      Number(host_status, "encoder_channels") != 2 || Number(host_status, "encoder_packet_ms_at_creation") != 10 ||
      Number(host_status, "encoder_bitrate_bps_at_creation") != 128000) {
    std::puts(host_status); std::puts(phone_status); return 1;
  }
  if (mdr_microphone_mute(host.get(), 0, error, sizeof(error))) { std::puts(error); return 1; }
  std::this_thread::sleep_for(std::chrono::milliseconds(200));
  if (mdr_status(host.get(), host_status, sizeof(host_status)) || Number(host_status, "bridge_nonzero_frames_provided") == 0) return 1;
  if (mdr_microphone_mute(host.get(), 1, error, sizeof(error))) return 1;
  if (mdr_status(host.get(), host_status, sizeof(host_status)) || mdr_status(phone.get(), phone_status, sizeof(phone_status))) return 1;
  const auto muted_frames = Number(host_status, "bridge_nonzero_frames_provided");
  const auto desktop_packets = Number(host_status, "packets_sent");
  const auto decoded_desktop = Number(phone_status, "decoded_distinct_stereo_frames");
  std::this_thread::sleep_for(std::chrono::milliseconds(200));
  if (mdr_status(host.get(), host_status, sizeof(host_status)) || mdr_status(phone.get(), phone_status, sizeof(phone_status)) ||
      Number(host_status, "bridge_nonzero_frames_provided") != muted_frames ||
      Number(host_status, "packets_sent") <= desktop_packets || Number(phone_status, "decoded_distinct_stereo_frames") <= decoded_desktop) return 1;
  if (mdr_microphone_mute(host.get(), 0, error, sizeof(error))) return 1;
  std::this_thread::sleep_for(std::chrono::milliseconds(200));
  if (mdr_status(host.get(), host_status, sizeof(host_status)) || Number(host_status, "bridge_nonzero_frames_provided") <= muted_frames) return 1;
  if (mdr_microphone_mute(host.get(), 1, error, sizeof(error))) return 1;
  if (mdr_status(host.get(), host_status, sizeof(host_status)) || mdr_status(phone.get(), phone_status, sizeof(phone_status))) return 1;
  const auto before_return = Number(host_status, "return_packets_received");
  const auto before_desktop = Number(phone_status, "decoded_distinct_stereo_frames");
  const auto before_gate = Number(host_status, "bridge_nonzero_frames_provided");
  const auto initial_ice = IceUser(offer);
  if (mdr_restart_offer(host.get(), offer, sizeof(offer), error, sizeof(error)) ||
      initial_ice.empty() || IceUser(offer).empty() || IceUser(offer) == initial_ice || !std::strstr(offer, "a=sendrecv") ||
      mdr_test_duplex_accept(phone.get(), offer, answer, sizeof(answer), error, sizeof(error)) ||
      mdr_answer(host.get(), answer, error, sizeof(error))) { std::puts(error); return 1; }
  bool restarted = false;
  for (int i = 0; i < 100; ++i) {
    std::this_thread::sleep_for(std::chrono::milliseconds(100));
    if (mdr_status(host.get(), host_status, sizeof(host_status)) || mdr_status(phone.get(), phone_status, sizeof(phone_status))) return 1;
    if (Number(host_status, "return_packets_received") > before_return + 10 &&
        Number(phone_status, "decoded_distinct_stereo_frames") > before_desktop + 24000) { restarted = true; break; }
  }
  if (!restarted || Number(host_status, "bridge_nonzero_frames_provided") != before_gate ||
      !std::strstr(host_status, "\"microphone_muted\":true")) return 1;
  if (mdr_microphone_mute(host.get(), 0, error, sizeof(error))) return 1;
  std::this_thread::sleep_for(std::chrono::milliseconds(200));
  if (mdr_status(host.get(), host_status, sizeof(host_status)) || Number(host_status, "bridge_nonzero_frames_provided") <= before_gate) return 1;
  std::puts("ICE restart renewed credentials on both existing peers; duplex/stereo and the microphone gate survived");
  std::puts("Duplex stock-Opus peer decoded both directions; microphone mute preserved stereo desktop playback");
  return 0;
}

int main() {
  if (mdr_abi_version() != 8) return 1;
  char error[512]{}, offer[65537]{}, answer[65537]{}, status[4096]{};
  mdr_peer* raw = nullptr;
  if (mdr_create_duplex(0, "", "", &raw, error, sizeof(error)) != 1 || raw != nullptr ||
      mdr_create_duplex(0, "same-cable", "SAME-CABLE", &raw, error, sizeof(error)) != 1 || raw != nullptr ||
      mdr_create_duplex(2, "", "chosen-cable", &raw, error, sizeof(error)) != 1 || raw != nullptr) return 1;
  if (mdr_create_duplex(0, "explicit-desktop", "explicit-nonexistent-cable", &raw, error, sizeof(error))) return 1;
  {
    Peer pending(raw, mdr_destroy);
    // Remote policy must never silently fall back to direct ICE without TURN.
    if (mdr_configure_ice(pending.get(), nullptr, 0, 1, error, sizeof(error)) != 1 ||
        mdr_configure_ice(pending.get(), nullptr, 0, 0, error, sizeof(error)) != 0) return 1;
    if (mdr_offer(pending.get(), offer, sizeof(offer), error, sizeof(error)) || !std::strstr(offer, "a=sendrecv") ||
        mdr_status(pending.get(), status, sizeof(status)) || Number(status, "pcm_frames_sent") != 0 ||
        Number(status, "bridge_frames_submitted") != 0 || !std::strstr(status, "\"microphone_muted\":true")) return 1;
  }
  if (mdr_create(3, "", &raw, error, sizeof(error)) != 1 || raw != nullptr) return 1;
  if (mdr_create(3, "explicit-nonexistent-cable", &raw, error, sizeof(error))) return 1;
  {
    Peer pending(raw, mdr_destroy);
    // Offer alone never touches a physical endpoint or clears the return gate.
    if (mdr_offer(pending.get(), offer, sizeof(offer), error, sizeof(error)) || !std::strstr(offer, "a=recvonly") ||
        mdr_status(pending.get(), status, sizeof(status)) || Number(status, "bridge_frames_submitted") != 0 ||
        !std::strstr(status, "\"microphone_muted\":true") ||
        mdr_microphone_mute(pending.get(), 0, error, sizeof(error)) != 1) return 1;
    if (mdr_restart_offer(pending.get(), answer, sizeof(answer), error, sizeof(error)) != 1) return 1;
    // Once authorized, a missing explicit endpoint must expose the fixed native
    // operation/HRESULT, release cleanly and never submit to a default output.
    if (mdr_create(4, "", &raw, error, sizeof(error))) return 1;
    Peer sender(raw, mdr_destroy);
    if (mdr_test_send_accept(sender.get(), offer, answer, sizeof(answer), error, sizeof(error)) ||
        mdr_answer(pending.get(), answer, error, sizeof(error))) return 1;
    bool failed = false;
    for (int i = 0; i < 50; ++i) {
      std::this_thread::sleep_for(std::chrono::milliseconds(100));
      if (mdr_status(pending.get(), status, sizeof(status))) return 1;
      if (std::strstr(status, "\"bridge_failed\":true")) { failed = true; break; }
    }
    if (!failed || Number(status, "bridge_error_hresult") == 0 || Number(status, "bridge_frames_submitted") != 0 ||
        !std::strstr(status, "Open selected microphone cable; rerun bridge-devices") ||
        mdr_microphone_mute(pending.get(), 0, error, sizeof(error)) != 1) return 1;
    std::puts("Explicit endpoint failure retained native operation/HRESULT without default fallback");
  }
  for (int session = 0; session < 3; ++session) {
    std::printf("Native session %d\n", session + 1);
    if (Session()) return 1;
    if (ReturnSession()) return 1;
    if (DuplexSession()) return 1;
  }
  return 0;
}
