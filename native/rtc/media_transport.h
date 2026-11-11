#pragma once
#include "api/stats/rtc_stats_report.h"
#include "api/stats/rtcstats_objects.h"
#include <set>
#include <string>

namespace micdrop {
// Never serialize a stats object or its identifiers. The candidate protocol is
// distinct from this endpoint's connection to TURN (relay_protocol).
struct MediaTransport {
  std::string local = "unavailable", remote = "unavailable";
  std::string candidate_protocol = "unavailable", relay_protocol = "unavailable";
  std::string Json() const {
    return "{\"version\":1,\"local_candidate_type\":\"" + local +
        "\",\"remote_candidate_type\":\"" + remote +
        "\",\"candidate_protocol\":\"" + candidate_protocol +
        "\",\"relay_protocol\":\"" + relay_protocol + "\"}";
  }
};

inline std::string CandidateType(const webrtc::RTCIceCandidateStats* candidate) {
  const auto type = candidate ? candidate->candidate_type.value_or("") : "";
  if (type == "host" || type == "srflx" || type == "prflx" || type == "relay") return type;
  return "unavailable";
}

inline const webrtc::RTCIceCandidatePairStats* SelectedAudioPair(const webrtc::RTCStatsReport& report) {
  // Follow audio RTP -> transport -> selected pair. A succeeded pair on some
  // other transport is not evidence for this audio session. Current sessions
  // use one audio transport; remain unknown if a future mode uses several.
  std::set<std::string> transports;
  const auto collect = [&](const auto& streams) {
    for (const auto* stream : streams) {
      if (stream->kind.value_or("") == "audio" && stream->transport_id)
        transports.insert(*stream->transport_id);
    }
  };
  collect(report.GetStatsOfType<webrtc::RTCInboundRtpStreamStats>());
  collect(report.GetStatsOfType<webrtc::RTCOutboundRtpStreamStats>());
  if (transports.size() != 1) return nullptr;
  const auto* transport = report.GetAs<webrtc::RTCTransportStats>(*transports.begin());
  if (!transport || !transport->selected_candidate_pair_id) return nullptr;
  const auto* pair = report.GetAs<webrtc::RTCIceCandidatePairStats>(*transport->selected_candidate_pair_id);
  // libwebrtc marks even an established selected pair in-progress while a
  // periodic STUN ping is outstanding. That is not a new ICE generation or
  // evidence of media loss. Keep its identity available for the engine's two
  // current-SDP username checks; peer/ICE state still determines connectivity.
  const auto state = pair ? pair->state.value_or("") : "";
  return state == "succeeded" || state == "in-progress" ? pair : nullptr;
}

inline MediaTransport SelectedMediaTransport(const webrtc::RTCStatsReport& report) {
  MediaTransport result;
  const auto* pair = SelectedAudioPair(report);
  if (!pair) return result;
  const auto* local = pair->local_candidate_id ?
      report.GetAs<webrtc::RTCLocalIceCandidateStats>(*pair->local_candidate_id) : nullptr;
  const auto* remote = pair->remote_candidate_id ?
      report.GetAs<webrtc::RTCRemoteIceCandidateStats>(*pair->remote_candidate_id) : nullptr;
  result.local = CandidateType(local);
  result.remote = CandidateType(remote);
  if (!local) return result;
  const auto protocol = local->protocol.value_or("");
  if (protocol == "udp" || protocol == "tcp") result.candidate_protocol = protocol;
  const auto relay = local->relay_protocol.value_or("");
  if (result.local == "host" || result.local == "srflx" || (result.local == "prflx" && relay.empty())) {
    result.relay_protocol = "not_applicable";
  } else if ((result.local == "relay" || result.local == "prflx") &&
             (relay == "udp" || relay == "tcp" || relay == "tls")) {
    result.relay_protocol = relay;
  }
  return result;
}
}  // namespace micdrop
