#include "media_transport.h"
#include "route_selection.h"
#include <cstdio>
#include <cstdlib>
#include <memory>

namespace {
void Check(bool ok) { if (!ok) { std::puts("Selected media transport contract failed"); std::abort(); } }
const auto now = webrtc::Timestamp::Micros(1000000);
template <typename T> T* Add(webrtc::RTCStatsReport& report, const char* id) {
  auto stat = std::make_unique<T>(id, now);
  auto* ptr = stat.get(); report.AddStats(std::move(stat)); return ptr;
}
void SelectedPair(bool sending, const std::string& hop) {
  auto report = webrtc::RTCStatsReport::Create(now);
  if (sending) {
    auto* audio = Add<webrtc::RTCOutboundRtpStreamStats>(*report, "audio");
    audio->kind = "audio"; audio->transport_id = "private-transport";
  } else {
    auto* audio = Add<webrtc::RTCInboundRtpStreamStats>(*report, "audio");
    audio->kind = "audio"; audio->transport_id = "private-transport";
  }
  auto* video = Add<webrtc::RTCOutboundRtpStreamStats>(*report, "video");
  video->kind = "video"; video->transport_id = "unrelated";
  auto* transport = Add<webrtc::RTCTransportStats>(*report, "private-transport");
  transport->selected_candidate_pair_id = "selected";
  auto* ignored = Add<webrtc::RTCIceCandidatePairStats>(*report, "a-first-pair");
  ignored->state = "succeeded"; ignored->local_candidate_id = "private-ignored";
  auto* ignored_local = Add<webrtc::RTCLocalIceCandidateStats>(*report, "private-ignored");
  ignored_local->candidate_type = "host";
  auto* pair = Add<webrtc::RTCIceCandidatePairStats>(*report, "selected");
  pair->state = "succeeded"; pair->local_candidate_id = "private-local"; pair->remote_candidate_id = "private-remote";
  auto* local = Add<webrtc::RTCLocalIceCandidateStats>(*report, "private-local");
  local->candidate_type = "relay"; local->protocol = "udp"; local->relay_protocol = hop;
  local->address = "private-address"; local->url = "turns:private-server";
  auto* remote = Add<webrtc::RTCRemoteIceCandidateStats>(*report, "private-remote");
  remote->candidate_type = "relay"; remote->relay_protocol = "tcp";
  local->username_fragment = "private-local-generation";
  remote->username_fragment = "private-remote-generation";
  auto selected = [&] { return micdrop::SelectedMediaTransport(*report); };
  Check(selected().local == "relay" && selected().remote == "relay");
  Check(selected().candidate_protocol == "udp" && selected().relay_protocol == hop);
  Check(selected().Json().find("private") == std::string::npos);
  // A selected/writable pair becomes in-progress on every STUN keepalive.
  // Preserve both credentials for engine.cc's current-description checks:
  // dropping them here used to report a false generation and restart audio.
  for (const char* state : {"in-progress", "succeeded", "in-progress", "succeeded"}) {
    pair->state = state;
    const auto* observed = micdrop::SelectedAudioPair(*report);
    Check(observed == pair);
    Check(report->GetAs<webrtc::RTCLocalIceCandidateStats>(*observed->local_candidate_id)
        ->username_fragment.value_or("") == "private-local-generation");
    Check(report->GetAs<webrtc::RTCRemoteIceCandidateStats>(*observed->remote_candidate_id)
        ->username_fragment.value_or("") == "private-remote-generation");
    Check(selected().local == "relay" && selected().remote == "relay");
    Check(selected().candidate_protocol == "udp" && selected().relay_protocol == hop);
    Check(selected().Json().find("private") == std::string::npos);
  }
  local->candidate_type = "prflx";
  Check(selected().relay_protocol == hop);
  local->relay_protocol.reset();
  Check(selected().relay_protocol == "not_applicable");
  local->candidate_type = "host";
  Check(selected().relay_protocol == "not_applicable"); // No inference from remote TURN hop.
  local->candidate_type = "relay";
  Check(selected().relay_protocol == "unavailable");
  local->relay_protocol = "private-secret"; local->protocol = "private-secret";
  Check(selected().relay_protocol == "unavailable" && selected().candidate_protocol == "unavailable");
  Check(selected().Json().find("private") == std::string::npos);
  for (const char* state : {"failed", "waiting", "frozen", "private-unknown"}) {
    pair->state = state;
    Check(micdrop::SelectedAudioPair(*report) == nullptr);
    Check(selected().local == "unavailable");
  }
  pair->state = "succeeded";
  pair->local_candidate_id = "private-remote"; // Wrong type must not be cast as local.
  Check(selected().local == "unavailable" && selected().relay_protocol == "unavailable");
  pair->local_candidate_id = "missing";
  Check(selected().local == "unavailable" && selected().remote == "relay");
  pair->local_candidate_id = "private-local";
  transport->selected_candidate_pair_id.reset();
  Check(selected().remote == "unavailable");
  transport->selected_candidate_pair_id = "selected";
  video->kind = "audio"; // Two audio transports cannot be summarized as one.
  Check(selected().local == "unavailable");
}
}  // namespace
int main() {
  micdrop::RouteSelection routes;
  auto first = routes.Observe("private-first", 0, true, false);
  Check(first.find("\"negotiated\":false") != std::string::npos);
  Check(first.find("\"observed_switches\":0") != std::string::npos);
  routes.Observe("", 0, true, true); // Missing sample retains the baseline.
  routes.Observe(std::string(513, 'x'), 0, true, true); // Bounded private state.
  Check(routes.Observe("private-first", 0, true, true).find("\"observed_switches\":0") != std::string::npos);
  auto changed = routes.Observe("private-second", 0, true, true);
  Check(changed.find("\"observed_switches\":1") != std::string::npos && changed.find("private") == std::string::npos);
  Check(routes.Observe("private-restart", 1, true, true).find("\"observed_switches\":1") != std::string::npos);
  Check(routes.Observe("private-later", 1, true, true).find("\"observed_switches\":2") != std::string::npos);
  Check(micdrop::SelectedMediaTransport(*webrtc::RTCStatsReport::Create(now)).local == "unavailable");
  for (bool sending : {false, true}) for (const auto* hop : {"udp", "tcp", "tls"}) SelectedPair(sending, hop);
  std::puts("Selected audio pair, TURN hop, unknowns and privacy contracts passed");
}
