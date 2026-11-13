#ifdef _WIN32
#define WIN32_LEAN_AND_MEAN
#include <winsock2.h>
#else
#include <arpa/inet.h>
#include <netinet/in.h>
#include <sys/socket.h>
#include <unistd.h>
#endif
#include "capi.h"
#include <cstdio>
#include <cstring>
#include <memory>
#include <string>

using Peer = std::unique_ptr<mdr_peer, decltype(&mdr_destroy)>;

// A bound UDP port deliberately sends no responses. This avoids ICMP "port
// unreachable" and keeps an actual WebRTC gathering task pending at its deadline.
struct SilentServer {
#ifdef _WIN32
  SOCKET socket = INVALID_SOCKET;
  bool initialized = false;
  std::string port;
  SilentServer() {
    WSADATA data{};
    initialized = WSAStartup(MAKEWORD(2, 2), &data) == 0;
    if (!initialized) return;
    socket = ::socket(AF_INET, SOCK_DGRAM, IPPROTO_UDP);
    if (socket == INVALID_SOCKET) return;
    sockaddr_in address{}; address.sin_family = AF_INET;
    if (bind(socket, reinterpret_cast<sockaddr*>(&address), sizeof(address))) return;
    int length = sizeof(address);
    if (getsockname(socket, reinterpret_cast<sockaddr*>(&address), &length)) return;
    port = std::to_string(ntohs(address.sin_port));
  }
  ~SilentServer() {
    if (socket != INVALID_SOCKET) closesocket(socket);
    if (initialized) WSACleanup();
  }
#else
  int socket = -1;
  std::string port;
  SilentServer() {
    socket = ::socket(AF_INET, SOCK_DGRAM, IPPROTO_UDP);
    if (socket < 0) return;
    sockaddr_in address{};
    address.sin_family = AF_INET;
    address.sin_addr.s_addr = htonl(INADDR_ANY);
    if (::bind(socket, reinterpret_cast<sockaddr*>(&address), sizeof(address)) != 0) return;
    socklen_t length = sizeof(address);
    if (::getsockname(socket, reinterpret_cast<sockaddr*>(&address), &length) != 0) return;
    port = std::to_string(ntohs(address.sin_port));
  }
  ~SilentServer() {
    if (socket >= 0) ::close(socket);
  }
#endif
};

static int Attempt(const SilentServer& server, bool force_relay) {
  char error[512]{}, offer[65537]{}, status[4096]{};
  mdr_peer* raw = nullptr;
  if (mdr_create(force_relay ? 1 : 7, "", &raw, error, sizeof(error))) { std::puts(error); return 1; }
  Peer peer(raw, mdr_destroy);
  const auto url = std::string(force_relay ? "turn:" : "stun:") + "127.0.0.1:" + server.port +
      (force_relay ? "?transport=udp" : "");
  const mdr_ice_server ice{url.c_str(), force_relay ? "test-user" : "", force_relay ? "test-password" : ""};
  if (mdr_configure_ice(peer.get(), &ice, 1, force_relay, error, sizeof(error))) { std::puts(error); return 1; }
  const auto result = mdr_offer(peer.get(), offer, sizeof(offer), error, sizeof(error));
  if (mdr_status(peer.get(), status, sizeof(status))) return 1;
  // Print only counters and the fixed error text, never the generated SDP.
  std::puts(status);
  if (!std::strstr(status, "\"pcm_frames_sent\":0")) return 1;
  if (force_relay) {
    if (!result || std::strcmp(error, "ICE candidate gathering timed out") ||
        !std::strstr(status, "\"result\":\"timed_out\"") ||
        !std::strstr(status, "\"relay_only\":true") ||
        !std::strstr(status, "\"relay_candidates\":0") ||
        !std::strstr(status, "\"ready_sections\":0")) return 1;
  } else if (result || !std::strstr(offer, "a=candidate:") ||
      !std::strstr(status, "\"result\":\"deadline_with_candidates\"") ||
      !std::strstr(status, "\"ready_sections\":1")) {
    std::puts(error); return 1;
  }
  if (!force_relay) {
    mdr_peer* receiver_raw = nullptr;
    char answer[65537]{};
    // The stock duplex peer reuses its offered transceiver on renegotiation.
    // The playback-only codec-preference helper is a one-off setup check.
    if (mdr_create(4, "", &receiver_raw, error, sizeof(error))) return 1;
    Peer receiver(receiver_raw, mdr_destroy);
    if (mdr_test_duplex_accept(receiver.get(), offer, answer, sizeof(answer), error, sizeof(error)) ||
        mdr_answer(peer.get(), answer, error, sizeof(error))) { std::puts(error); return 1; }
    auto user = [](const std::string& sdp) {
      const auto start = sdp.find("a=ice-ufrag:");
      return start == std::string::npos ? std::string() : sdp.substr(start, sdp.find("\r\n", start) - start);
    };
    const auto before = user(offer);
    // Avoid depending on whether WebRTC reuses a completed allocation from
    // initial gathering. A new silent endpoint gives the restart fresh work.
    SilentServer renewed_server;
    if (renewed_server.port.empty()) return 1;
    const auto renewed_url = "stun:127.0.0.1:" + renewed_server.port;
    const mdr_ice_server renewed_ice{renewed_url.c_str(), "", ""};
    if (mdr_configure_ice(peer.get(), &renewed_ice, 1, 0, error, sizeof(error)) ||
        mdr_restart_offer(peer.get(), offer, sizeof(offer), error, sizeof(error))) { std::puts(error); return 1; }
    if (mdr_status(peer.get(), status, sizeof(status))) return 1;
    std::puts(status);
    if (before.empty() || user(offer).empty() || before == user(offer) ||
        (!std::strstr(status, "\"result\":\"deadline_with_candidates\"") &&
         !std::strstr(status, "\"result\":\"complete\""))) {
      std::puts("Restart did not provide renewed, usable candidates"); return 1;
    }
    if (mdr_test_duplex_accept(receiver.get(), offer, answer, sizeof(answer), error, sizeof(error)) ||
        mdr_answer(peer.get(), answer, error, sizeof(error))) { std::puts(error); return 1; }
  }
  return 0;
}

int main() {
  SilentServer server;
  if (server.port.empty()) return 1;
  if (Attempt(server, false) || Attempt(server, true)) return 1;
  std::puts("Initial and renewed ICE preserved current candidates; forced relay failed closed without TURN");
  return 0;
}
