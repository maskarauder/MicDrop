#include "capi.h"
#include "audio_device.h"
#include "ice_gathering.h"
#include "media_transport.h"
#include "route_selection.h"
#include "windows_certificate_verifier.h"
#include "api/audio_codecs/audio_decoder_factory_template.h"
#include "api/audio_codecs/audio_encoder_factory_template.h"
#include "api/audio_codecs/opus/audio_decoder_opus.h"
#include "api/audio_codecs/opus/audio_encoder_opus.h"
#include "api/create_peerconnection_factory.h"
#include "api/jsep.h"
#include "api/make_ref_counted.h"
#include "api/peer_connection_interface.h"
#include "api/set_local_description_observer_interface.h"
#include "api/set_remote_description_observer_interface.h"
#include "api/stats/rtc_stats_collector_callback.h"
#include "api/stats/rtcstats_objects.h"
#include "pc/session_description.h"
#include "rtc_base/logging.h"
#include "rtc_base/ssl_adapter.h"
#include "rtc_base/thread.h"
#include "rtc_base/win32_socket_init.h"
#include <algorithm>
#include <atomic>
#include <chrono>
#include <condition_variable>
#include <cstring>
#include <future>
#include <iomanip>
#include <map>
#include <mutex>
#include <sstream>
#include <stdexcept>
#include <type_traits>

namespace {
using namespace std::chrono_literals;
// Explicit music encoder policy; no SDP string rewriting or voice processing.
struct MusicOpus : webrtc::AudioEncoderOpus {
  static std::optional<Config> SdpToConfig(const webrtc::SdpAudioFormat& format) {
    auto config = webrtc::AudioEncoderOpus::SdpToConfig(format);
    if (config) {
      config->frame_size_ms = 10;
      config->supported_frame_lengths_ms = {10};
      config->application = Config::ApplicationMode::kAudio;
      config->bitrate_bps = 128000;
      config->dtx_enabled = false;
    }
    return config;
  }
  static void AppendSupportedEncoders(std::vector<webrtc::AudioCodecSpec>* specs) {
    webrtc::AudioEncoderOpus::AppendSupportedEncoders(specs);
    for (auto& spec : *specs) {
      spec.format.parameters["stereo"] = "1";
      spec.format.parameters["sprop-stereo"] = "1";
      spec.format.parameters["minptime"] = "10";
    }
  }
};
// Receive stereo explicitly. Opus' RTP declaration is always /48000/2, but
// without this fmtp preference a receiver may request mono encoding.
struct StereoOpusDecoder : webrtc::AudioDecoderOpus {
  static void AppendSupportedDecoders(std::vector<webrtc::AudioCodecSpec>* codecs) {
    webrtc::AudioDecoderOpus::AppendSupportedDecoders(codecs);
    for (auto& codec : *codecs) codec.format.parameters["stereo"] = "1";
  }
};
class MusicEncoderFactory : public webrtc::AudioEncoderFactory {
 public:
  std::atomic<size_t> channels{0}, packet_ms{0};
  std::atomic<int> initial_bitrate{0};
  std::vector<webrtc::AudioCodecSpec> GetSupportedEncoders() override {
    std::vector<webrtc::AudioCodecSpec> codecs; MusicOpus::AppendSupportedEncoders(&codecs); return codecs;
  }
  std::optional<webrtc::AudioCodecInfo> QueryAudioEncoder(const webrtc::SdpAudioFormat& format) override {
    auto config = MusicOpus::SdpToConfig(format);
    return config ? std::optional(MusicOpus::QueryAudioEncoder(*config)) : std::nullopt;
  }
  std::unique_ptr<webrtc::AudioEncoder> Create(const webrtc::Environment& env,
      const webrtc::SdpAudioFormat& format, Options options) override {
    auto config = MusicOpus::SdpToConfig(format);
    if (!config) return nullptr;
    auto encoder = MusicOpus::MakeAudioEncoder(env, *config, options);
    if (encoder) {
      channels = encoder->NumChannels(); packet_ms = encoder->Num10MsFramesInNextPacket() * 10;
      initial_bitrate = encoder->GetTargetBitrate();
    }
    return encoder;
  }
};
class LocalDone : public webrtc::SetLocalDescriptionObserverInterface {
 public:
  std::promise<bool> done;
  void OnSetLocalDescriptionComplete(webrtc::RTCError error) override { done.set_value(error.ok()); }
};
class RemoteDone : public webrtc::SetRemoteDescriptionObserverInterface {
 public:
  std::promise<bool> done;
  void OnSetRemoteDescriptionComplete(webrtc::RTCError error) override { done.set_value(error.ok()); }
};
class CreatedDone : public webrtc::CreateSessionDescriptionObserver {
 public:
  std::promise<std::unique_ptr<webrtc::SessionDescriptionInterface>> done;
  void OnSuccess(webrtc::SessionDescriptionInterface* sdp) override { done.set_value(std::unique_ptr<webrtc::SessionDescriptionInterface>(sdp)); }
  void OnFailure(webrtc::RTCError) override { done.set_value(nullptr); }
};
struct StatsResult { std::string json, pair_id, local_username, remote_username; };
class StatsDone : public webrtc::RTCStatsCollectorCallback {
 public:
  std::promise<StatsResult> done;
  void OnStatsDelivered(const webrtc::scoped_refptr<const webrtc::RTCStatsReport>& report) override {
    uint64_t packets = 0, bytes = 0;
    bool opus = false;
    std::optional<double> target_bitrate;
    uint64_t incoming_packets = 0, incoming_bytes = 0;
    for (const auto* incoming : report->GetStatsOfType<webrtc::RTCInboundRtpStreamStats>()) {
      if (incoming->kind.value_or("") != "audio") continue;
      incoming_packets += incoming->packets_received.value_or(0);
      incoming_bytes += incoming->bytes_received.value_or(0);
      if (incoming->codec_id) {
        const auto* codec = report->GetAs<webrtc::RTCCodecStats>(*incoming->codec_id);
        opus = codec && codec->mime_type.value_or("") == "audio/opus";
      }
    }
    for (const auto* outbound : report->GetStatsOfType<webrtc::RTCOutboundRtpStreamStats>()) {
      if (outbound->kind.value_or("") != "audio") continue;
      packets += outbound->packets_sent.value_or(0);
      bytes += outbound->bytes_sent.value_or(0);
      target_bitrate = outbound->target_bitrate;
      if (outbound->codec_id) {
        const auto* codec = report->GetAs<webrtc::RTCCodecStats>(*outbound->codec_id);
        opus = codec && codec->mime_type.value_or("") == "audio/opus";
      }
    }
    const auto* pair = micdrop::SelectedAudioPair(*report);
    const auto* local = pair && pair->local_candidate_id ?
        report->GetAs<webrtc::RTCLocalIceCandidateStats>(*pair->local_candidate_id) : nullptr;
    const auto* remote = pair && pair->remote_candidate_id ?
        report->GetAs<webrtc::RTCRemoteIceCandidateStats>(*pair->remote_candidate_id) : nullptr;
    done.set_value({"\"packets_sent\":" + std::to_string(packets) + ",\"bytes_sent\":" +
        std::to_string(bytes) + ",\"opus\":" + (opus ? "true" : "false") +
        ",\"target_bitrate_bps\":" + (target_bitrate ? std::to_string(*target_bitrate) : "null") +
        ",\"return_packets_received\":" + std::to_string(incoming_packets) +
        ",\"return_bytes_received\":" + std::to_string(incoming_bytes) +
        ",\"media_transport\":" + micdrop::SelectedMediaTransport(*report).Json(), pair ? pair->id() : "",
        local ? local->username_fragment.value_or("") : "", remote ? remote->username_fragment.value_or("") : ""});
  }
};
void Check(bool good, const char* message) { if (!good) throw std::runtime_error(message); }
void Await(std::future<bool>& future, std::chrono::milliseconds timeout = 15s) {
  Check(future.wait_for(timeout) == std::future_status::ready && future.get(), "WebRTC description failed or timed out");
}
void Copy(const std::string& value, char* out, size_t capacity) {
  Check(out && value.size() < capacity, "Output buffer too small");
  std::memcpy(out, value.c_str(), value.size() + 1);
}
template<typename F> int Guard(char* error, size_t size, F&& operation) noexcept {
  try { operation(); if (error && size) error[0] = '\0'; return 0; }
  catch (const std::exception& e) {
    if (error && size) { const size_t n = std::min(std::strlen(e.what()), size - 1); std::memcpy(error, e.what(), n); error[n] = '\0'; }
    return 1;
  } catch (...) { if (error && size) error[0] = '\0'; return 1; }
}
}  // namespace

struct mdr_peer : webrtc::PeerConnectionObserver {
  // The native DLL must work without a Go/net caller initializing Winsock.
  // Declared first so socket initialization outlives all threads and peers.
  webrtc::WinsockInitializer winsock;
  std::unique_ptr<webrtc::Thread> network, worker, signaling;
  webrtc::scoped_refptr<micdrop::AudioDevice> device;
  webrtc::scoped_refptr<MusicEncoderFactory> encoders;
  webrtc::scoped_refptr<webrtc::PeerConnectionFactoryInterface> factory;
  webrtc::scoped_refptr<webrtc::PeerConnectionInterface> connection;
  std::shared_ptr<micdrop::TLSVerificationDiagnostics> tls_verification =
      std::make_shared<micdrop::TLSVerificationDiagnostics>();
  std::atomic<webrtc::PeerConnectionInterface::PeerConnectionState> state{webrtc::PeerConnectionInterface::PeerConnectionState::kNew};
  std::mutex ice_mutex;
  std::condition_variable ice_ready;
  bool gathered = false;
  micdrop::IceGatheringSummary gathering_summary;
  const char* gathering_result = "not_started";
  int64_t gathering_elapsed_ms = 0;
  uint32_t gathering_errors = 0;
  int gathering_last_error = 0;
  bool signaling_started = false;
  bool continuous = false;
  std::atomic<uint64_t> ice_restarts{0};
  micdrop::RouteSelection route_selection; // Accessed only on signaling thread.
  const int source;

  explicit mdr_peer(int source_value) : source(source_value) {}
  template<typename F> auto Signal(F&& operation) {
    using Result = decltype(operation());
    std::promise<Result> result; auto future = result.get_future();
    signaling->BlockingCall([&] {
      try {
        if constexpr (std::is_void_v<Result>) { operation(); result.set_value(); }
        else result.set_value(operation());
      } catch (...) { result.set_exception(std::current_exception()); }
    });
    return future.get();
  }
  void Start(const char* endpoint, const char* return_endpoint = "", bool renomination = false, bool continual = false) {
    continuous = continual;
    Check(winsock.error() == 0, "Windows sockets initialization failed");
    static std::once_flag initialize;
    std::call_once(initialize, [] {
      webrtc::LogMessage::LogToDebug(webrtc::LS_NONE);
      webrtc::LogMessage::SetLogToStderr(false);
      Check(webrtc::InitializeSSL(), "WebRTC TLS initialization failed");
    });
    network = webrtc::Thread::CreateWithSocketServer();
    worker = webrtc::Thread::Create(); signaling = webrtc::Thread::Create();
    Check(network->Start() && worker->Start() && (signaling_started = signaling->Start()), "WebRTC threads failed");
    device = webrtc::make_ref_counted<micdrop::AudioDevice>(source == 4 ? 1 : source,
        endpoint ? endpoint : "", return_endpoint ? return_endpoint : "");
    encoders = webrtc::make_ref_counted<MusicEncoderFactory>();
    Signal([&] {
      // Receivers and the microphone test sender use stock Opus capabilities,
      // like Android's prebuilt factory, rather than desktop music preferences.
      webrtc::scoped_refptr<webrtc::AudioEncoderFactory> encoder_factory = encoders;
      auto decoder_factory = webrtc::CreateAudioDecoderFactory<StereoOpusDecoder>();
      if (!micdrop::DesktopSource(source) || source == 4) {
        encoder_factory = webrtc::CreateAudioEncoderFactory<webrtc::AudioEncoderOpus>();
        decoder_factory = webrtc::CreateAudioDecoderFactory<webrtc::AudioDecoderOpus>();
      }
      if (micdrop::MicrophoneReturn(source))
        decoder_factory = webrtc::CreateAudioDecoderFactory<webrtc::AudioDecoderOpus>();
      factory = webrtc::CreatePeerConnectionFactory(network.get(), worker.get(), signaling.get(), device,
          encoder_factory, decoder_factory, nullptr, nullptr, nullptr, nullptr);
      Check(factory != nullptr, "WebRTC factory failed");
      webrtc::PeerConnectionInterface::RTCConfiguration config;
      config.sdp_semantics = webrtc::SdpSemantics::kUnifiedPlan;
      config.enable_ice_renomination = renomination;
      config.continual_gathering_policy = continuous ? webrtc::PeerConnectionInterface::GATHER_CONTINUALLY
                                                   : webrtc::PeerConnectionInterface::GATHER_ONCE;
      // LAN defaults have no discovery servers; remote mode explicitly configures ICE before an offer.
      webrtc::PeerConnectionDependencies dependencies(this);
      dependencies.tls_cert_verifier = std::make_unique<micdrop::WindowsCertificateVerifier>(tls_verification);
      auto result = factory->CreatePeerConnectionOrError(config, std::move(dependencies));
      Check(result.ok(), "WebRTC peer creation failed"); connection = result.MoveValue();
      const bool sending = micdrop::DesktopSource(source) || source == 4;
      connection->SetAudioRecording(sending);
      connection->SetAudioPlayout(!sending || micdrop::MicrophoneReturn(source));
      if (micdrop::DesktopSource(source)) {
        webrtc::AudioOptions options;
        options.echo_cancellation = false; options.auto_gain_control = false;
        options.noise_suppression = false; options.highpass_filter = false;
        auto audio = factory->CreateAudioSource(options);
        auto track = factory->CreateAudioTrack("desktop-output", audio.get());
        webrtc::RtpTransceiverInit init;
        init.direction = micdrop::MicrophoneReturn(source) ? webrtc::RtpTransceiverDirection::kSendRecv
                                                         : webrtc::RtpTransceiverDirection::kSendOnly;
        init.stream_ids = {"micdrop-desktop"};
        auto transceiver = connection->AddTransceiver(track, init);
        Check(transceiver.ok(), "WebRTC audio transceiver failed");
      } else if (!sending) {
        webrtc::RtpTransceiverInit init;
        init.direction = webrtc::RtpTransceiverDirection::kRecvOnly;
        auto transceiver = connection->AddTransceiver(webrtc::MediaType::AUDIO, init);
        Check(transceiver.ok(), "Microphone receive transceiver failed");
      }
    });
  }
  ~mdr_peer() override {
    if (signaling_started) signaling->BlockingCall([&] {
      // Stop native callbacks on the ADM control thread before releasing the
      // factory-owned AudioTransport they call into.
      if (device) worker->BlockingCall([&] { device->Terminate(); });
      if (connection) connection->Close();
      connection = nullptr; factory = nullptr;
    });
    if (device) device->Terminate();
    device = nullptr;
    if (signaling) signaling->Stop();
    if (worker) worker->Stop();
    if (network) network->Stop();
  }
  void Remote(webrtc::SdpType type, const char* sdp) {
    Check(sdp && std::strlen(sdp) <= 65536, "Invalid SDP size");
    auto description = webrtc::CreateSessionDescription(type, sdp);
    Check(description != nullptr, "Invalid session description");
    if (type == webrtc::SdpType::kOffer) {
      std::lock_guard lock(ice_mutex); gathered = false;
    }
    const bool renegotiating = Signal([&] { return connection->remote_description() != nullptr; });
    auto observer = webrtc::make_ref_counted<RemoteDone>(); auto future = observer->done.get_future();
    Signal([&] { connection->SetRemoteDescription(std::move(description), observer); });
    Await(future, renegotiating ? 5s : 15s);
  }
  void TestReceiverPreferences() {
    Signal([&] {
      // Match Android: codec preferences are set before the initial offer,
      // never rebuilt on ICE recovery. After offer association the SDK can
      // retain an unused initial receive transceiver alongside the active one.
      if (connection->remote_description() != nullptr) return;
      auto transceivers = connection->GetTransceivers();
      Check(transceivers.size() == 1, "Test receiver transceiver unavailable");
      auto transceiver = transceivers[0];
      auto codecs = factory->GetRtpReceiverCapabilities(webrtc::MediaType::AUDIO).codecs;
      std::erase_if(codecs, [](const auto& codec) { return codec.name != "opus"; });
      Check(codecs.size() == 1, "Stock Opus capability unavailable");
      auto modified = codecs;
      modified[0].parameters["stereo"] = "1";
      modified[0].parameters["sprop-stereo"] = "1";
      Check(!transceiver->SetCodecPreferences(modified).ok(), "Modified capabilities unexpectedly accepted");
      Check(transceiver->SetCodecPreferences(codecs).ok(), "Original Opus capability rejected");
    });
  }
  void TestMicrophoneSender(bool duplex = false) {
    Signal([&] {
      auto transceivers = connection->GetTransceivers();
      Check(source == 4 && transceivers.size() == 1, "Stock microphone transceiver unavailable");
      auto transceiver = transceivers[0];
      Check(transceiver->media_type() == webrtc::MediaType::AUDIO, "Expected audio offer");
      webrtc::AudioOptions options;
      options.echo_cancellation = false; options.auto_gain_control = false;
      options.noise_suppression = false; options.highpass_filter = false;
      auto audio = factory->CreateAudioSource(options);
      auto track = factory->CreateAudioTrack("phone-microphone", audio.get());
      // An explicit send-only transceiver created before a receive-only offer
      // is not associated with that m-section. Attach to the offered one.
      Check(transceiver->sender()->SetTrack(track.get()), "Stock microphone track unavailable");
      Check(transceiver->SetDirectionWithError(duplex ? webrtc::RtpTransceiverDirection::kSendRecv
                                                    : webrtc::RtpTransceiverDirection::kSendOnly).ok(), "Microphone direction failed");
      if (duplex) connection->SetAudioPlayout(true);
      auto codecs = factory->GetRtpSenderCapabilities(webrtc::MediaType::AUDIO).codecs;
      std::erase_if(codecs, [](const auto& codec) { return codec.name != "opus"; });
      Check(codecs.size() == 1 && transceiver->SetCodecPreferences(codecs).ok(), "Stock microphone Opus preference failed");
    });
  }
  // Signaling thread only. Continual descriptions carry candidates exclusively
  // in snapshots; each snapshot proves ownership from the SDK candidate itself.
  std::string LocalDescription(bool include_candidates) {
    const auto* local = connection->local_description();
    std::string sdp; Check(local && local->ToString(&sdp), "ICE description unavailable");
    if (!continuous) return sdp;
    const auto& contents = local->description()->contents();
    std::vector<std::string> candidates(contents.size());
    if (include_candidates) for (size_t i = 0; i < contents.size(); ++i) {
      const auto* transport = local->description()->GetTransportInfoByName(contents[i].mid());
      const auto* collection = local->candidates(i);
      if (!transport || !collection || contents[i].rejected) continue;
      for (size_t j = 0; j < collection->count(); ++j) {
        const auto* c = collection->at(j);
        if (c->candidate().username() != transport->description.ice_ufrag) continue;
        std::string value; Check(c->ToString(&value), "ICE candidate unavailable");
        candidates[i] += "a=" + value + "\r\n";
      }
    }
    std::string result; size_t section = 0; bool media = false;
    std::istringstream lines(sdp); std::string line;
    while (std::getline(lines, line)) {
      if (!line.empty() && line.back() == '\r') line.pop_back();
      if (line.starts_with("m=")) {
        if (media) { result += candidates.at(section); ++section; }
        media = true;
      }
      if (!line.starts_with("a=candidate:") && line != "a=end-of-candidates") result += line + "\r\n";
    }
    if (media) result += candidates.at(section);
    return result;
  }
  std::string Local(bool android_answer = false, bool ice_restart = false, bool trickle = false) {
    const auto started = std::chrono::steady_clock::now();
    {
      std::lock_guard lock(ice_mutex);
      gathering_summary = {}; gathering_result = "description_pending";
      gathering_elapsed_ms = 0; gathering_errors = 0; gathering_last_error = 0;
    }
    std::unique_ptr<webrtc::SessionDescriptionInterface> description;
    std::map<std::string, std::pair<std::string, std::string>> previous_ice;
    if (ice_restart) {
      Check(!android_answer, "Invalid restart direction");
      Signal([&] { Check(connection->signaling_state() == webrtc::PeerConnectionInterface::kStable &&
          connection->remote_description() != nullptr, "Restart requires an answered peer");
        const auto* local = connection->local_description();
        Check(local && local->description(), "Restart requires local credentials");
        for (const auto& content : local->description()->contents()) {
          if (content.rejected) continue;
          const auto* transport = local->description()->GetTransportInfoByName(content.mid());
          Check(transport != nullptr, "Restart transport unavailable");
          previous_ice[content.mid()] = {transport->description.ice_ufrag, transport->description.ice_pwd};
        }
      });
      { std::lock_guard lock(ice_mutex); gathered = false; }
      auto created = webrtc::make_ref_counted<CreatedDone>(); auto result = created->done.get_future();
      Signal([&] {
        webrtc::PeerConnectionInterface::RTCOfferAnswerOptions options; options.ice_restart = true;
        connection->CreateOffer(created.get(), options);
      });
      Check(result.wait_for(5s) == std::future_status::ready, "Restart offer creation timed out");
      description = result.get(); Check(description != nullptr, "Restart offer creation failed");
    }
    if (android_answer) {
      auto created = webrtc::make_ref_counted<CreatedDone>(); auto result = created->done.get_future();
      Signal([&] { connection->CreateAnswer(created.get(), webrtc::PeerConnectionInterface::RTCOfferAnswerOptions()); });
      Check(result.wait_for(15s) == std::future_status::ready, "Answer creation timed out");
      auto answer = result.get(); Check(answer != nullptr, "Answer creation failed");
      std::string sdp; Check(answer->ToString(&sdp), "Answer unavailable");
      // Match Android's narrow local-answer stereo preference. This generated
      // test SDP has one audio section and one codec. Kotlin tests cover the
      // general section/payload parser used by the app itself.
      const size_t opus = sdp.find(" opus/48000/2\r\n");
      const size_t map = sdp.rfind("a=rtpmap:", opus);
      Check(opus != std::string::npos && map != std::string::npos, "Opus answer unavailable");
      const auto prefix = "a=fmtp:" + sdp.substr(map + 9, opus - map - 9) + " ";
      const size_t fmtp = sdp.find(prefix);
      Check(fmtp != std::string::npos, "Stock Opus format parameters unavailable");
      const size_t end = sdp.find("\r\n", fmtp);
      size_t stereo = sdp.find(";stereo=", fmtp);
      if (stereo == std::string::npos || stereo >= end) stereo = sdp.find(" stereo=", fmtp);
      if (stereo == std::string::npos || stereo >= end) sdp.insert(end, ";stereo=1");
      else {
        const size_t value = stereo + 8;
        Check(value < end && (sdp[value] == '0' || sdp[value] == '1'), "Unexpected stereo answer parameter");
        sdp[value] = '1';
      }
      description = webrtc::CreateSessionDescription(webrtc::SdpType::kAnswer, sdp);
      Check(description != nullptr, "Stereo answer invalid");
    }
    auto observer = webrtc::make_ref_counted<LocalDone>(); auto future = observer->done.get_future();
    Signal([&] {
      if (description) connection->SetLocalDescription(std::move(description), observer);
      else connection->SetLocalDescription(observer);
    });
    Await(future, ice_restart ? 5s : 15s);
    const auto deadline = std::chrono::steady_clock::now() + (ice_restart ? 5s : 15s);
    const bool fast_relay = !ice_restart && Signal([&] {
      const auto config = connection->GetConfiguration();
      std::vector<std::string> urls;
      for (const auto& server : config.servers) urls.insert(urls.end(), server.urls.begin(), server.urls.end());
      return micdrop::SingleUDPRelay(config.type == webrtc::PeerConnectionInterface::kRelay, urls);
    });
    micdrop::InitialRelayGathering early(fast_relay);
    if (!fast_relay && !trickle) {
      std::unique_lock lock(ice_mutex);
      ice_ready.wait_until(lock, deadline, [&] { return gathered; });
    }
    auto snapshot = [&](bool deadline_reached) -> std::optional<std::string> {
      const auto* local = connection->local_description();
      Check(local && local->description(), "Session description unavailable");
      const auto config = connection->GetConfiguration();
      micdrop::IceGatheringSummary summary;
      summary.relay_only = config.type == webrtc::PeerConnectionInterface::kRelay;
      const auto& contents = local->description()->contents();
      for (size_t i = 0; i < contents.size(); ++i) {
        const auto& content = contents[i];
        if (content.rejected) continue;
        const auto* transport = local->description()->GetTransportInfoByName(content.mid());
        if (ice_restart) {
          const auto before = previous_ice.find(content.mid());
          Check(transport && before != previous_ice.end() && micdrop::FreshIceCredentials(
              before->second.first, before->second.second, transport->description.ice_ufrag,
              transport->description.ice_pwd), "Restart credentials were not renewed");
        }
        const auto* candidates = local->candidates(i);
        bool rtp = false, rtcp = false;
        if (candidates) for (size_t j = 0; j < candidates->count(); ++j) {
          const auto& candidate = candidates->at(j)->candidate();
          const auto kind = candidate.is_relay() ? micdrop::IceCandidateKind::Relay :
              candidate.is_local() ? micdrop::IceCandidateKind::Host :
              candidate.is_stun() ? micdrop::IceCandidateKind::Reflexive : micdrop::IceCandidateKind::Other;
          const bool current = transport && !transport->description.ice_ufrag.empty() &&
              candidate.username() == transport->description.ice_ufrag;
          if (summary.Add(kind, current, candidate.component())) {
            rtp |= candidate.component() == 1; rtcp |= candidate.component() == 2;
          }
        }
        const auto* media = content.media_description();
        summary.Section(rtp && media && media->type() == webrtc::MediaType::AUDIO,
            rtcp, media && media->rtcp_mux());
      }
      // Initial forced single-UDP relay can submit after eligible candidates
      // have remained present for 500ms. Serialize this same snapshot on the
      // signaling thread. Other configurations retain complete/deadline behavior.
      const bool complete = connection->ice_gathering_state() == webrtc::PeerConnectionInterface::kIceGatheringComplete;
      const auto elapsed = std::chrono::duration_cast<std::chrono::milliseconds>(std::chrono::steady_clock::now() - started).count();
      const bool ready = !complete && !deadline_reached && early.Ready(summary.Usable(), elapsed);
      if (!trickle && !complete && !deadline_reached && !ready) return std::nullopt;
      const auto result = micdrop::FinishGathering(complete, !config.servers.empty(), summary, ready);
      {
        std::lock_guard lock(ice_mutex);
        gathering_summary = summary; gathering_result = trickle ? "trickle" : micdrop::GatheringResultName(result);
        gathering_elapsed_ms = elapsed;
      }
      Check(trickle || result != micdrop::IceGatheringResult::TimedOut, "ICE candidate gathering timed out");
      Check(trickle || result != micdrop::IceGatheringResult::NoCandidates, "ICE gathering finished without usable candidates");
      std::string sdp;
      Check(local->ToString(&sdp), "Session description unavailable");
      return continuous ? LocalDescription(false) : sdp;
    };
    for (;;) {
      auto value = Signal([&] { return snapshot(!fast_relay || std::chrono::steady_clock::now() >= deadline); });
      if (value) return *value;
      std::unique_lock lock(ice_mutex);
      ice_ready.wait_until(lock, fast_relay ? std::min(deadline, std::chrono::steady_clock::now() + 50ms) : deadline,
          [&] { return gathered; });
    }
  }
  std::string GatheringStatus() {
    std::lock_guard lock(ice_mutex);
    const auto& s = gathering_summary;
    std::ostringstream out;
    out << "{\"result\":\"" << gathering_result << "\",\"elapsed_ms\":" << gathering_elapsed_ms
        << ",\"relay_only\":" << (s.relay_only ? "true" : "false")
        << ",\"host_candidates\":" << s.host << ",\"reflexive_candidates\":" << s.reflexive
        << ",\"relay_candidates\":" << s.relay << ",\"other_candidates\":" << s.other
        << ",\"media_sections\":" << s.media_sections << ",\"ready_sections\":" << s.ready_sections
        << ",\"candidate_errors\":" << gathering_errors << ",\"last_error_code\":" << gathering_last_error << '}';
    return out.str();
  }
  std::string Status() {
    auto observer = webrtc::make_ref_counted<StatsDone>(); auto future = observer->done.get_future();
    Signal([&] { connection->GetStats(observer.get()); });
    Check(future.wait_for(3s) == std::future_status::ready, "WebRTC statistics timed out");
    const auto stats = future.get();
    bool current_generation = false;
    const auto route = Signal([&] {
      const auto generation = ice_restarts.load();
      // During a restart the old selected pair can remain visible. Count only
      // pairs proven to belong to both new descriptions; absent proof is unknown.
      const bool current = generation == 0 ||
          (micdrop::AudioUsernameMatches(connection->local_description(), stats.local_username) &&
           micdrop::AudioUsernameMatches(connection->remote_description(), stats.remote_username));
      current_generation = current;
      return route_selection.Observe(current ? stats.pair_id : "", generation,
          micdrop::AudioRenomination(connection->local_description()),
          micdrop::AudioRenomination(connection->remote_description()));
    });
    const char* name = "new";
    using State = webrtc::PeerConnectionInterface::PeerConnectionState;
    switch (state.load()) {
      case State::kConnecting: name = "connecting"; break;
      case State::kConnected: name = "connected"; break;
      case State::kDisconnected: name = "disconnected"; break;
      case State::kFailed: name = "failed"; break;
      case State::kClosed: name = "closed"; break;
      default: break;
    }
    std::ostringstream out;
    const bool bridge_failed = micdrop::MicrophoneReturn(source) && device->BridgeFailed();
    const auto bridge_error = device->BridgeError();
    const auto tls = tls_verification->Snapshot();
    out << "{\"state\":\"" << name << "\",\"capture_failed\":" << (micdrop::DesktopSource(source) && device->CaptureFailed() ? "true" : "false")
        << ",\"continuous_gathering\":" << (continuous ? "true" : "false")
        << ",\"ice_generation_current\":" << (current_generation ? "true" : "false")
        << ",\"ice_restarts\":" << ice_restarts.load()
        << ",\"ice_gathering\":" << GatheringStatus()
        << ",\"tls_certificate_verification\":{\"checks\":" << tls.checks
        << ",\"failures\":" << tls.failures << ",\"last_error_code\":" << tls.last_error << '}'
        << ",\"audio_direction\":\"" << (source >= 5 ? "duplex" : source == 3 ? "phone_microphone" : "desktop_playback") << "\""
        << ",\"bridge_failed\":" << (bridge_failed ? "true" : "false")
        << ",\"bridge_error_hresult\":" << bridge_error.hresult
        << ",\"bridge_error_operation\":" << std::quoted(bridge_error.message)
        << ",\"microphone_muted\":" << (device->MicrophoneMuted() ? "true" : "false")
        << ",\"bridge_frames_submitted\":" << device->BridgeFrames()
        << ",\"bridge_nonzero_frames_provided\":" << device->BridgeNonzeroFrames()
        << ",\"bridge_buffer_frames\":" << device->BridgeBufferFrames()
        << ",\"bridge_mix_rate_hz\":" << device->BridgeMixRate()
        << ",\"bridge_mix_channels\":" << device->BridgeMixChannels()
        << ",\"source_rate_hz\":" << device->SourceRate() << ",\"source_channels\":" << device->SourceChannels()
        << ",\"pcm_frames_sent\":" << device->SentFrames() << ",\"decoded_nonzero_frames\":" << device->ReceivedFrames()
        << ",\"decoded_distinct_stereo_frames\":" << device->StereoFrames()
        << ",\"encoder_channels\":" << encoders->channels.load()
        << ",\"encoder_packet_ms_at_creation\":" << encoders->packet_ms.load()
        << ",\"encoder_bitrate_bps_at_creation\":" << encoders->initial_bitrate.load()
        << ",\"route_selection\":" << route << ',' << stats.json << '}';
    return out.str();
  }
  void OnSignalingChange(webrtc::PeerConnectionInterface::SignalingState) override {}
  void OnDataChannel(webrtc::scoped_refptr<webrtc::DataChannelInterface>) override {}
  void OnIceCandidate(const webrtc::IceCandidate*) override {}
  void OnIceCandidateError(const std::string&, int, const std::string&, int code, const std::string&) override {
    std::lock_guard lock(ice_mutex);
    ++gathering_errors; gathering_last_error = code;
  }
  void OnConnectionChange(webrtc::PeerConnectionInterface::PeerConnectionState value) override { state = value; }
  void OnIceGatheringChange(webrtc::PeerConnectionInterface::IceGatheringState value) override {
    if (value == webrtc::PeerConnectionInterface::kIceGatheringComplete) {
      { std::lock_guard lock(ice_mutex); gathered = true; } ice_ready.notify_all();
    }
  }
};

extern "C" {
uint32_t mdr_abi_version(void) { return 8; }
int mdr_configure_ice(mdr_peer* peer, const mdr_ice_server* servers, size_t count,
    int force_relay, char* error, size_t size) {
  return Guard(error, size, [&] {
    Check(peer && count <= 8 && (count == 0 || servers) && (force_relay == 0 || force_relay == 1), "Invalid ICE configuration");
    peer->Signal([&] {
      auto config = peer->connection->GetConfiguration();
      config.servers.clear();
      bool has_turn = false;
      for (size_t i = 0; i < count; ++i) {
        const auto& s = servers[i];
        Check(s.url && s.username && s.credential && std::strlen(s.url) <= 512 &&
            std::strlen(s.username) <= 512 && std::strlen(s.credential) <= 512, "Invalid ICE server");
        const std::string url(s.url);
        const bool turn = url.starts_with("turn:") || url.starts_with("turns:");
        Check(turn || url.starts_with("stun:"), "Invalid ICE scheme");
        Check(!turn || (*s.username && *s.credential), "TURN credentials required");
        webrtc::PeerConnectionInterface::IceServer server;
        server.urls = {url}; server.username = s.username; server.password = s.credential;
        config.servers.push_back(std::move(server)); has_turn |= turn;
      }
      Check(!force_relay || has_turn, "Forced relay requires TURN");
      config.type = force_relay ? webrtc::PeerConnectionInterface::kRelay : webrtc::PeerConnectionInterface::kAll;
      Check(peer->connection->SetConfiguration(config).ok(), "WebRTC rejected ICE configuration");
    });
  });
}
int mdr_create(int source, const char* endpoint, mdr_peer** out, char* error, size_t size) {
  return mdr_create_configured(source, endpoint, 0, 0, out, error, size);
}
int mdr_create_configured(int source, const char* endpoint, int renomination, int continuous,
    mdr_peer** out, char* error, size_t size) {
  if (out) *out = nullptr;
  return Guard(error, size, [&] {
    Check(out && (continuous == 0 || continuous == 1) && (renomination == 0 || renomination == 1) && ((source >= 0 && source <= 4) || source == 7) &&
        (source != 3 || (endpoint && *endpoint && std::strlen(endpoint) <= 1023)), "Invalid peer configuration");
    auto peer = std::make_unique<mdr_peer>(source); peer->Start(endpoint, "", renomination != 0, continuous != 0); *out = peer.release();
  });
}
int mdr_create_duplex(int probe, const char* capture_endpoint, const char* return_endpoint,
    mdr_peer** out, char* error, size_t size) {
  return mdr_create_duplex_configured(probe, capture_endpoint, return_endpoint, 0, 0, out, error, size);
}
int mdr_create_duplex_configured(int probe, const char* capture_endpoint, const char* return_endpoint,
    int renomination, int continuous, mdr_peer** out, char* error, size_t size) {
  if (out) *out = nullptr;
  return Guard(error, size, [&] {
    Check(out && (continuous == 0 || continuous == 1) && (renomination == 0 || renomination == 1) && (probe == 0 || probe == 1) && capture_endpoint && std::strlen(capture_endpoint) <= 1023 &&
        return_endpoint && *return_endpoint && std::strlen(return_endpoint) <= 1023, "Invalid duplex configuration");
    Check(probe || _stricmp(capture_endpoint, return_endpoint) != 0,
        "Desktop capture cannot use the microphone return cable");
    auto peer = std::make_unique<mdr_peer>(probe ? 6 : 5);
    peer->Start(capture_endpoint, return_endpoint, renomination != 0, continuous != 0); *out = peer.release();
  });
}
int mdr_offer(mdr_peer* peer, char* sdp, size_t capacity, char* error, size_t size) {
  return Guard(error, size, [&] { Check(peer != nullptr, "Invalid offer peer"); Copy(peer->Local(), sdp, capacity); });
}
int mdr_trickle_offer(mdr_peer* peer, char* sdp, size_t capacity, char* error, size_t size) {
  return Guard(error, size, [&] {
    Check(peer != nullptr, "Invalid offer peer");
    peer->Signal([&] {
      Check(peer->connection->local_description() == nullptr, "Initial trickle only");
    });
    Copy(peer->Local(false, false, true), sdp, capacity);
  });
}
int mdr_local_ice(mdr_peer* peer, char* sdp, size_t capacity, int* complete, char* error, size_t size) {
  return Guard(error, size, [&] {
    Check(peer && complete, "Invalid ICE snapshot");
    peer->Signal([&] {
      const auto value = peer->LocalDescription(true);
      Copy(value, sdp, capacity);
      *complete = peer->connection->ice_gathering_state() == webrtc::PeerConnectionInterface::kIceGatheringComplete;
    });
  });
}
static int ChangeICE(mdr_peer* peer, const char* mid, int index, const char* ufrag,
    const char* candidate, bool remove, char* error, size_t size) {
  return Guard(error, size, [&] {
    Check(peer && mid && ufrag && candidate && std::strlen(mid) <= 64 && std::strlen(ufrag) <= 256 &&
        std::strlen(candidate) <= 2048 && std::strpbrk(candidate, "\r\n") == nullptr && index >= 0 && index < 8, "Invalid ICE candidate");
    peer->Signal([&] {
      const auto* remote = peer->connection->remote_description();
      Check(remote && remote->description(), "ICE answer required");
      const auto& contents = remote->description()->contents();
      Check(static_cast<size_t>(index) < contents.size() && contents[index].mid() == mid && !contents[index].rejected,
          "ICE media section mismatch");
      const auto* transport = remote->description()->GetTransportInfoByName(mid);
      Check(transport && !transport->description.ice_ufrag.empty() && transport->description.ice_ufrag == ufrag,
          "ICE generation mismatch");
      webrtc::SdpParseError parse_error;
      std::unique_ptr<webrtc::IceCandidate> parsed(webrtc::CreateIceCandidate(mid, index, candidate, &parse_error));
      Check(parsed != nullptr, "ICE candidate rejected");
      Check(parsed->candidate().username().empty() || parsed->candidate().username() == ufrag, "ICE candidate generation mismatch");
      Check(peer->connection->GetConfiguration().type != webrtc::PeerConnectionInterface::kRelay ||
          parsed->candidate().is_relay(), "Relay policy rejected candidate");
      if (remove) peer->connection->RemoveIceCandidate(parsed.get()); // Idempotent removal.
      else Check(peer->connection->AddIceCandidate(parsed.get()), "ICE candidate rejected");
    });
  });
}
int mdr_add_ice(mdr_peer* peer, const char* mid, int index, const char* ufrag,
    const char* candidate, char* error, size_t size) {
  return ChangeICE(peer, mid, index, ufrag, candidate, false, error, size);
}
int mdr_remove_ice(mdr_peer* peer, const char* mid, int index, const char* ufrag,
    const char* candidate, char* error, size_t size) {
  return ChangeICE(peer, mid, index, ufrag, candidate, true, error, size);
}
int mdr_restart_offer(mdr_peer* peer, char* sdp, size_t capacity, char* error, size_t size) {
  return Guard(error, size, [&] { Check(peer != nullptr, "Invalid restart peer"); Copy(peer->Local(false, true, peer->continuous), sdp, capacity); ++peer->ice_restarts; });
}
int mdr_microphone_mute(mdr_peer* peer, int muted, char* error, size_t size) {
  return Guard(error, size, [&] {
    Check(peer && micdrop::MicrophoneReturn(peer->source) && (muted == 0 || muted == 1), "Invalid microphone control");
    Check(peer->device->SetMicrophoneMuted(muted != 0), "Microphone cable did not apply mute state");
  });
}
int mdr_test_duplex_accept(mdr_peer* peer, const char* offer, char* answer, size_t capacity, char* error, size_t size) {
  return Guard(error, size, [&] {
    Check(peer && peer->source == 4, "Invalid stock duplex test peer");
    peer->Remote(webrtc::SdpType::kOffer, offer);
    peer->TestMicrophoneSender(true);
    Copy(peer->Local(true, false, peer->continuous), answer, capacity);
    peer->device->Authorize();
  });
}
int mdr_test_send_accept(mdr_peer* peer, const char* offer, char* answer, size_t capacity, char* error, size_t size) {
  return Guard(error, size, [&] {
    Check(peer && peer->source == 4, "Invalid stock test sender");
    peer->Remote(webrtc::SdpType::kOffer, offer);
    peer->TestMicrophoneSender();
    Copy(peer->Local(false, false, peer->continuous), answer, capacity);
    peer->device->Authorize();
  });
}
int mdr_answer(mdr_peer* peer, const char* sdp, char* error, size_t size) {
  return Guard(error, size, [&] { Check(peer != nullptr, "Invalid answer peer"); peer->Remote(webrtc::SdpType::kAnswer, sdp); peer->device->Authorize(); });
}
int mdr_test_accept(mdr_peer* peer, const char* offer, char* answer, size_t capacity, char* error, size_t size) {
  return Guard(error, size, [&] {
    Check(peer && peer->source == 2, "Invalid test receiver");
    peer->TestReceiverPreferences(); peer->Remote(webrtc::SdpType::kOffer, offer);
    Copy(peer->Local(true, false, peer->continuous), answer, capacity);
  });
}
int mdr_status(mdr_peer* peer, char* json, size_t capacity) {
  return Guard(nullptr, 0, [&] { Check(peer != nullptr, "Invalid peer"); Copy(peer->Status(), json, capacity); });
}
void mdr_destroy(mdr_peer* peer) { delete peer; }
}
