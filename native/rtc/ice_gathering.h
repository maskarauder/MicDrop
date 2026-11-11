#pragma once
#include <cstdint>
#include <optional>
#include <string>
#include <vector>

namespace micdrop {

inline bool FreshIceCredentials(const std::string& previous_user, const std::string& previous_password,
    const std::string& user, const std::string& password) {
  return !previous_user.empty() && !previous_password.empty() && !user.empty() && !password.empty() &&
      previous_user != user && previous_password != password;
}

enum class IceCandidateKind { Host, Reflexive, Relay, Other };

// Counts only: no SDP, network addresses, ICE usernames or TURN credentials.
struct IceGatheringSummary {
  uint32_t host = 0, reflexive = 0, relay = 0, other = 0;
  uint32_t media_sections = 0, ready_sections = 0;
  bool relay_only = false;

  // A candidate must belong to the current local ICE generation. Component 1
  // carries RTP; component 2 is required too when RTCP is not multiplexed.
  bool Add(IceCandidateKind kind, bool current_generation, int component) {
    switch (kind) {
      case IceCandidateKind::Host: ++host; break;
      case IceCandidateKind::Reflexive: ++reflexive; break;
      case IceCandidateKind::Relay: ++relay; break;
      default: ++other; break;
    }
    return current_generation && (component == 1 || component == 2) &&
        kind != IceCandidateKind::Other && (!relay_only || kind == IceCandidateKind::Relay);
  }
  void Section(bool rtp, bool rtcp, bool mux) {
    ++media_sections;
    if (rtp && (mux || rtcp)) ++ready_sections;
  }
  bool Usable() const { return media_sections > 0 && ready_sections == media_sections; }
};

// Only one explicitly configured UDP TURN path may finish early. Direct ICE,
// multiple relays, TCP/TLS fallback and every restart retain their full budget.
inline bool SingleUDPRelay(bool relay_only, const std::vector<std::string>& urls) {
  if (!relay_only) return false;
  size_t turns = 0;
  bool udp = false;
  for (const auto& url : urls) {
    if (url.starts_with("turn:") || url.starts_with("turns:")) {
      ++turns; udp = url.starts_with("turn:") && url.ends_with("?transport=udp");
    } else if (!url.starts_with("stun:")) return false;
  }
  return turns == 1 && udp;
}

class InitialRelayGathering {
 public:
  explicit InitialRelayGathering(bool enabled) : enabled_(enabled) {}
  bool Ready(bool usable, int64_t now_ms) {
    if (!enabled_ || !usable) { ready_at_.reset(); return false; }
    if (!ready_at_) ready_at_ = now_ms;
    return now_ms - *ready_at_ >= 500;
  }
 private:
  bool enabled_;
  std::optional<int64_t> ready_at_;
};

enum class IceGatheringResult { Complete, CandidatesReady, DeadlineWithCandidates, TimedOut, NoCandidates };

inline IceGatheringResult FinishGathering(bool complete, bool allow_partial,
    const IceGatheringSummary& candidates, bool early_ready = false) {
  if (complete) return candidates.Usable() ? IceGatheringResult::Complete : IceGatheringResult::NoCandidates;
  if (allow_partial && candidates.Usable()) return early_ready ? IceGatheringResult::CandidatesReady : IceGatheringResult::DeadlineWithCandidates;
  return IceGatheringResult::TimedOut;
}

inline const char* GatheringResultName(IceGatheringResult result) {
  switch (result) {
    case IceGatheringResult::Complete: return "complete";
    case IceGatheringResult::CandidatesReady: return "candidates_ready";
    case IceGatheringResult::DeadlineWithCandidates: return "deadline_with_candidates";
    case IceGatheringResult::TimedOut: return "timed_out";
    case IceGatheringResult::NoCandidates: return "no_candidates";
  }
  return "unavailable";
}

}  // namespace micdrop
