#include "capi.h"
#include <chrono>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <memory>
#include <sstream>
#include <string>
#include <thread>
#include <vector>

using Peer = std::unique_ptr<mdr_peer, decltype(&mdr_destroy)>;
static void Check(bool ok, const char* reason) {
  if (!ok) { std::puts(reason); std::exit(1); }
}
static std::vector<std::string> Lines(const std::string& sdp) {
  std::vector<std::string> lines;
  for (size_t at = 0; at < sdp.size();) {
    const auto end = sdp.find("\r\n", at); if (end == std::string::npos) break;
    lines.push_back(sdp.substr(at, end - at)); at = end + 2;
  }
  return lines;
}
static std::string WithoutCandidates(const std::string& sdp) {
  std::string value;
  for (const auto& line : Lines(sdp))
    if (!line.starts_with("a=candidate:") && line != "a=end-of-candidates") value += line + "\r\n";
  return value;
}
static std::string Field(const std::string& sdp, const char* name) {
  for (const auto& line : Lines(sdp)) if (line.starts_with(name)) return line.substr(std::strlen(name));
  return {};
}
static void Deliver(mdr_peer* from, mdr_peer* to, const std::string& protocol) {
  char sdp[65537]{}, error[512]{}; int complete = 0;
  for (int attempt = 0; attempt < 60; ++attempt) {
    int count = 0;
    Check(!mdr_local_ice(from, sdp, sizeof(sdp), &complete, error, sizeof(error)), error);
    const auto mid = Field(sdp, "a=mid:"), user = Field(sdp, "a=ice-ufrag:");
    for (const auto& line : Lines(sdp)) {
      if (!line.starts_with("a=candidate:")) continue;
      std::istringstream tokens(line); std::string foundation, component, transport;
      tokens >> foundation >> component >> transport;
      if (transport != protocol) continue;
      Check(!mdr_add_ice(to, mid.c_str(), 0, user.c_str(), line.substr(2).c_str(), error, sizeof(error)), error);
      ++count;
    }
    if (count > 0) return;
    std::this_thread::sleep_for(std::chrono::milliseconds(100));
  }
  Check(false, "Required TCP/UDP candidate was not gathered");
}
static std::string Status(mdr_peer* peer) {
  char value[4096]{}; Check(!mdr_status(peer, value, sizeof(value)), "status unavailable"); return value;
}
static uint64_t Number(const std::string& status, const char* name) {
  const auto key = "\"" + std::string(name) + "\":";
  const auto at = status.find(key); Check(at != std::string::npos, "missing numeric diagnostic");
  return std::stoull(status.substr(at + key.size()));
}
static bool Has(const std::string& value, const char* field) { return value.find(field) != std::string::npos; }
static Peer Create(int source, bool enabled, bool legacy = false, bool continuous = false) {
  char error[512]{}; mdr_peer* raw = nullptr;
  Check(!(legacy ? mdr_create(source, "", &raw, error, sizeof(error)) :
      mdr_create_configured(source, "", enabled ? 1 : 0, continuous ? 1 : 0, &raw, error, sizeof(error))), error);
  return Peer(raw, mdr_destroy);
}
static void Descriptions(mdr_peer* host, mdr_peer* phone, bool continuous = false) {
  char error[512]{}, offer[65537]{}, answer[65537]{};
  Check(!(continuous ? mdr_trickle_offer(host, offer, sizeof(offer), error, sizeof(error)) :
      mdr_offer(host, offer, sizeof(offer), error, sizeof(error))), error);
  Check(!mdr_test_accept(phone, WithoutCandidates(offer).c_str(), answer, sizeof(answer), error, sizeof(error)), error);
  Check(!mdr_answer(host, WithoutCandidates(answer).c_str(), error, sizeof(error)), error);
}

int main(int argc, char**) {
  const bool continuous = argc > 1;
  // A legacy/default peer must still advertise no support, and mixed versions
  // must connect normally with negotiated=false.
  {
    auto host = Create(1, false, true), phone = Create(2, true);
    Descriptions(host.get(), phone.get());
    Check(Has(Status(host.get()), "\"local_renomination\":false"), "LAN default changed");
    Check(Has(Status(phone.get()), "\"negotiated\":false"), "Mixed support incorrectly negotiated");
    Deliver(host.get(), phone.get(), "udp"); Deliver(phone.get(), host.get(), "udp");
    bool received = false;
    for (int i = 0; i < 100; ++i) {
      std::this_thread::sleep_for(std::chrono::milliseconds(100));
      if (Number(Status(phone.get()), "decoded_nonzero_frames") > 0) { received = true; break; }
    }
    Check(received, "Mixed support did not preserve audio");
  }
  auto host = Create(1, true, false, continuous), phone = Create(2, true, false, continuous);
  Descriptions(host.get(), phone.get(), continuous);
  Check(Has(Status(host.get()), continuous ? "\"continuous_gathering\":true" : "\"continuous_gathering\":false"), "Gathering policy was not applied");
  Check(Has(Status(host.get()), "\"negotiated\":true") && Has(Status(phone.get()), "\"negotiated\":true"),
      "Both actual descriptions must advertise renomination");
  Deliver(host.get(), phone.get(), "tcp"); Deliver(phone.get(), host.get(), "tcp");
  bool tcp = false; uint64_t frames = 0, switches = 0;
  for (int i = 0; i < 150; ++i) {
    std::this_thread::sleep_for(std::chrono::milliseconds(100));
    const auto incoming = Status(phone.get()), outgoing = Status(host.get());
    if (Has(incoming, "\"candidate_protocol\":\"tcp\"") && Has(outgoing, "\"candidate_protocol\":\"tcp\"") &&
        (frames = Number(incoming, "decoded_nonzero_frames")) > 0) {
      tcp = true; switches = Number(incoming, "observed_switches"); break;
    }
  }
  Check(tcp, "Audio did not establish on the initial TCP route");
  Deliver(host.get(), phone.get(), "udp"); Deliver(phone.get(), host.get(), "udp");
  for (int i = 0; i < 200; ++i) {
    std::this_thread::sleep_for(std::chrono::milliseconds(100));
    const auto incoming = Status(phone.get()), outgoing = Status(host.get());
    if (Has(incoming, "\"candidate_protocol\":\"udp\"") && Has(outgoing, "\"candidate_protocol\":\"udp\"") &&
        Number(incoming, "decoded_nonzero_frames") > frames && Number(incoming, "observed_switches") > switches) {
      Check(Number(incoming, "ice_restarts") == 0 && Number(outgoing, "ice_restarts") == 0,
          "Route change restarted ICE");
      std::puts("Negotiated peers switched live audio from TCP to later UDP on the same peers without ICE restart.");
      if (!continuous) return 0;
      // Removing a departed alternative is idempotent and bound to credentials.
      // Real SDK candidates remain private; never print the snapshot itself.
      char before[65537]{}, error[512]{}, offer[65537]{}, answer[65537]{}; int complete = 0;
      Check(!mdr_local_ice(host.get(), before, sizeof(before), &complete, error, sizeof(error)), error);
      Check(!complete, "Continual gathering must remain open");
      const auto old_user = Field(before, "a=ice-ufrag:"), mid = Field(before, "a=mid:");
      std::string old_candidate;
      for (const auto& line : Lines(before)) if (line.starts_with("a=candidate:") && line.find(" tcp ") != std::string::npos) {
        old_candidate = line.substr(2);
        Check(!mdr_remove_ice(phone.get(), mid.c_str(), 0, old_user.c_str(), old_candidate.c_str(), error, sizeof(error)), error);
        Check(!mdr_remove_ice(phone.get(), mid.c_str(), 0, old_user.c_str(), old_candidate.c_str(), error, sizeof(error)), error);
      }
      Check(!old_candidate.empty(), "Removal test needs a TCP alternative");
      Check(!mdr_restart_offer(host.get(), offer, sizeof(offer), error, sizeof(error)), error);
      Check(Field(offer, "a=ice-ufrag:") != old_user && !Has(offer, "a=candidate:"), "Restart did not create a fresh candidate-free description");
      Check(!mdr_test_accept(phone.get(), offer, answer, sizeof(answer), error, sizeof(error)), error);
      Check(!Has(answer, "a=candidate:"), "Continual answer must use snapshot exchange");
      Check(!mdr_answer(host.get(), answer, error, sizeof(error)), error);
      Check(mdr_add_ice(phone.get(), mid.c_str(), 0, old_user.c_str(), old_candidate.c_str(), error, sizeof(error)) == 1, "Stale addition accepted after restart");
      Check(mdr_remove_ice(phone.get(), mid.c_str(), 0, old_user.c_str(), old_candidate.c_str(), error, sizeof(error)) == 1, "Stale removal accepted after restart");
      Deliver(host.get(), phone.get(), "udp"); Deliver(phone.get(), host.get(), "udp");
      const auto before_frames = Number(incoming, "decoded_nonzero_frames");
      for (int j = 0; j < 100; ++j) {
        std::this_thread::sleep_for(std::chrono::milliseconds(100));
        const auto recovered = Status(host.get());
        if (Has(recovered, "\"state\":\"connected\"") && Has(recovered, "\"ice_generation_current\":true") &&
            Number(Status(phone.get()), "decoded_nonzero_frames") > before_frames + 24000) {
          Check(Number(Status(host.get()), "ice_restarts") == 1, "Unexpected extra ICE restart");
          std::puts("Continual peers retained live audio, removed candidates, rejected stale updates and resumed snapshots after ICE restart.");
          return 0;
        }
      }
      Check(false, "Continual peer did not recover with fresh candidates");
    }
  }
  std::puts("Later UDP route was not selected by both peers"); return 1;
}
