#include "../../native/rtc/ice_gathering.h"
#include <cstdio>
#include <initializer_list>

using micdrop::IceCandidateKind;
using micdrop::IceGatheringResult;
using micdrop::IceGatheringSummary;
using micdrop::FinishGathering;

int main() {
  bool ok = true;
  IceGatheringSummary relay;
  relay.relay_only = true;
  // A TURN allocation can finish while another interface keeps gathering.
  const bool rtp = relay.Add(IceCandidateKind::Relay, true, 1);
  relay.Section(rtp, false, true);
  ok &= FinishGathering(false, true, relay) == IceGatheringResult::DeadlineWithCandidates;
  ok &= FinishGathering(false, true, relay, true) == IceGatheringResult::CandidatesReady;
  ok &= FinishGathering(true, true, relay) == IceGatheringResult::Complete;
  ok &= relay.host == 0 && relay.relay == 1 && relay.ready_sections == 1;
  // LAN callers retain their existing complete-gathering contract.
  ok &= FinishGathering(false, false, relay) == IceGatheringResult::TimedOut;
  ok &= micdrop::FreshIceCredentials("old", "old-password", "new", "new-password");
  ok &= !micdrop::FreshIceCredentials("old", "old-password", "old", "new-password");
  ok &= !micdrop::FreshIceCredentials("old", "old-password", "new", "old-password");
  ok &= !micdrop::FreshIceCredentials("", "old-password", "new", "new-password");

  for (auto kind : {IceCandidateKind::Host, IceCandidateKind::Reflexive, IceCandidateKind::Other}) {
    IceGatheringSummary direct;
    direct.relay_only = true;
    direct.Section(direct.Add(kind, true, 1), false, true);
    ok &= FinishGathering(false, true, direct) == IceGatheringResult::TimedOut;
    ok &= FinishGathering(true, true, direct) == IceGatheringResult::NoCandidates;
  }
  // Neither an earlier generation's relay nor RTCP alone can authorize RTP.
  for (bool current : {false, true}) {
    IceGatheringSummary unusable;
    unusable.relay_only = true;
    const bool eligible = unusable.Add(IceCandidateKind::Relay, current, current ? 2 : 1);
    unusable.Section(!current && eligible, current && eligible, true);
    ok &= !unusable.Usable();
  }
  IceGatheringSummary multiple = relay;
  multiple.Section(false, false, true);
  ok &= !multiple.Usable(); // Every active section needs its own candidates.
  IceGatheringSummary no_mux;
  no_mux.Section(true, false, false);
  ok &= !no_mux.Usable();
  IceGatheringSummary with_rtcp;
  with_rtcp.Section(true, true, false);
  ok &= with_rtcp.Usable();
  IceGatheringSummary empty;
  ok &= FinishGathering(true, true, empty) == IceGatheringResult::NoCandidates;
  ok &= FinishGathering(false, true, empty) == IceGatheringResult::TimedOut;
  ok &= FinishGathering(false, true, empty, true) == IceGatheringResult::TimedOut;
  IceGatheringSummary direct;
  direct.Section(direct.Add(IceCandidateKind::Host, true, 1), false, true);
  ok &= FinishGathering(false, true, direct) == IceGatheringResult::DeadlineWithCandidates;

  const std::string udp = "turn:relay.test:3478?transport=udp";
  ok &= micdrop::SingleUDPRelay(true, {udp});
  ok &= micdrop::SingleUDPRelay(true, {"stun:relay.test:3478", udp});
  ok &= !micdrop::SingleUDPRelay(false, {udp});
  ok &= !micdrop::SingleUDPRelay(true, {});
  ok &= !micdrop::SingleUDPRelay(true, {"stun:relay.test:3478"});
  ok &= !micdrop::SingleUDPRelay(true, {udp, udp});
  ok &= !micdrop::SingleUDPRelay(true, {udp, "turn:relay2.test:3478?transport=udp"});
  ok &= !micdrop::SingleUDPRelay(true, {udp, "turns:relay.test:5349?transport=tcp"});
  ok &= !micdrop::SingleUDPRelay(true, {"turn:relay.test:3478?transport=tcp"});
  ok &= !micdrop::SingleUDPRelay(true, {"turns:relay.test:5349?transport=tcp"});
  micdrop::InitialRelayGathering early(true), disabled(false);
  ok &= !early.Ready(false, 0);
  ok &= !early.Ready(true, 100) && !early.Ready(true, 599) && early.Ready(true, 600);
  ok &= !early.Ready(false, 601);
  ok &= !early.Ready(true, 700) && !early.Ready(true, 1199) && early.Ready(true, 1200);
  ok &= !disabled.Ready(true, 0) && !disabled.Ready(true, 15000);

  if (!ok) std::puts("ICE gathering deadline or forced-relay contract failed");
  return ok ? 0 : 1;
}
