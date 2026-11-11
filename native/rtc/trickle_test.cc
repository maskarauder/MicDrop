#include "capi.h"
#include <chrono>
#include <cstdio>
#include <cstring>
#include <memory>
#include <string>
#include <thread>
#include <vector>

using Peer = std::unique_ptr<mdr_peer, decltype(&mdr_destroy)>;
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
static bool Deliver(mdr_peer* from, mdr_peer* to, bool check_rejection) {
  char sdp[65537]{}, error[512]{}; int complete = 0;
  if (mdr_local_ice(from, sdp, sizeof(sdp), &complete, error, sizeof(error))) return false;
  const auto mid = Field(sdp, "a=mid:"), user = Field(sdp, "a=ice-ufrag:");
  int count = 0;
  for (const auto& line : Lines(sdp)) {
    if (!line.starts_with("a=candidate:")) continue;
    const auto candidate = line.substr(2);
    if (check_rejection && mdr_add_ice(to, mid.c_str(), 0, "obsolete-generation", candidate.c_str(), error, sizeof(error)) != 1)
      return false;
    if (mdr_add_ice(to, mid.c_str(), 0, user.c_str(), candidate.c_str(), error, sizeof(error))) return false;
    // Real SDK duplicate delivery, not only the Go deduplication contract.
    if (mdr_add_ice(to, mid.c_str(), 0, user.c_str(), candidate.c_str(), error, sizeof(error))) return false;
    ++count;
  }
  return count > 0;
}

int main() {
  char error[512]{}, offer[65537]{}, answer[65537]{}, status[4096]{};
  mdr_peer* raw = nullptr;
  if (mdr_create(1, "", &raw, error, sizeof(error))) return 1;
  Peer host(raw, mdr_destroy);
  if (mdr_create(2, "", &raw, error, sizeof(error))) return 1;
  Peer phone(raw, mdr_destroy);
  if (mdr_trickle_offer(host.get(), offer, sizeof(offer), error, sizeof(error))) { std::puts(error); return 1; }
  if (mdr_status(host.get(), status, sizeof(status)) || !std::strstr(status, "\"result\":\"trickle\"") ||
      !std::strstr(status, "\"pcm_frames_sent\":0")) return 1;
  const auto early_offer = WithoutCandidates(offer);
  if (mdr_test_accept(phone.get(), early_offer.c_str(), answer, sizeof(answer), error, sizeof(error))) { std::puts(error); return 1; }
  const auto early_answer = WithoutCandidates(answer);
  if (mdr_answer(host.get(), early_answer.c_str(), error, sizeof(error))) { std::puts(error); return 1; }
  // No embedded candidates: trickling must supply candidates in both directions.
  bool delivered = false;
  for (int i = 0; i < 100; ++i) {
    std::this_thread::sleep_for(std::chrono::milliseconds(100));
    if (!delivered) delivered = Deliver(host.get(), phone.get(), true) && Deliver(phone.get(), host.get(), true);
    if (delivered && !mdr_status(phone.get(), status, sizeof(status)) && std::strstr(status, "\"state\":\"connected\"") &&
        !std::strstr(status, "\"decoded_nonzero_frames\":0")) {
      std::puts("Candidate-free descriptions connected through later authenticated candidates; stale credentials rejected.");
      return 0;
    }
  }
  std::puts("Trickle-only audio did not connect"); return 1;
}
