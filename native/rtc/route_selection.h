#pragma once
#include "api/jsep.h"
#include "pc/session_description.h"
#include <algorithm>
#include <cstdint>
#include <string>

namespace micdrop {
// Read the actual SDK descriptions, not the requested configuration. Every
// active audio section must advertise support. Empty/rejected SDP is unknown.
inline bool AudioRenomination(const webrtc::SessionDescriptionInterface* sdp) {
  if (!sdp || !sdp->description()) return false;
  bool audio = false;
  for (const auto& content : sdp->description()->contents()) {
    if (content.rejected || !content.media_description() ||
        content.media_description()->type() != webrtc::MediaType::AUDIO) continue;
    audio = true;
    const auto* transport = sdp->description()->GetTransportInfoByName(content.mid());
    if (!transport || !transport->description.HasOption(webrtc::ICE_OPTION_RENOMINATION)) return false;
  }
  return audio;
}

inline bool AudioUsernameMatches(const webrtc::SessionDescriptionInterface* sdp, const std::string& username) {
  if (username.empty() || !sdp || !sdp->description()) return false;
  bool audio = false;
  for (const auto& content : sdp->description()->contents()) {
    if (content.rejected || !content.media_description() ||
        content.media_description()->type() != webrtc::MediaType::AUDIO) continue;
    audio = true;
    const auto* transport = sdp->description()->GetTransportInfoByName(content.mid());
    if (!transport || transport->description.ice_ufrag != username) return false;
  }
  return audio;
}

class RouteSelection {
 public:
  // Sampling can miss intermediate switches. Keep one bounded private ID; no
  // candidate, address, credential or ID is serialized. A restart resets the
  // comparison baseline, never inflates the within-generation switch count.
  std::string Observe(const std::string& pair, uint64_t generation, bool local, bool remote) {
    if (generation != generation_) { previous_.clear(); generation_ = generation; }
    if (!pair.empty() && pair.size() <= 512) {
      if (!previous_.empty() && pair != previous_) switches_ = std::min(switches_ + 1, limit);
      previous_ = pair;
    }
    return "{\"version\":1,\"local_renomination\":" + std::string(local ? "true" : "false") +
        ",\"remote_renomination\":" + (remote ? "true" : "false") +
        ",\"negotiated\":" + (local && remote ? "true" : "false") +
        ",\"generation\":" + std::to_string(std::min(generation, limit)) +
        ",\"observed_switches\":" + std::to_string(switches_) + "}";
  }
 private:
  static constexpr uint64_t limit = 1000000;
  uint64_t generation_ = 0, switches_ = 0;
  std::string previous_;
};
}  // namespace micdrop
