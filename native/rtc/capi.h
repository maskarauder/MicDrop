#ifndef MICDROP_RTC_CAPI_H
#define MICDROP_RTC_CAPI_H
#include <stddef.h>
#include <stdint.h>
#if defined(_WIN32) && defined(MICDROP_RTC_EXPORTS)
#define MDR_API __declspec(dllexport)
#elif !defined(_WIN32) && defined(MICDROP_RTC_EXPORTS)
#define MDR_API __attribute__((visibility("default")))
#else
#define MDR_API
#endif
#ifdef __cplusplus
extern "C" {
#endif
typedef struct mdr_peer mdr_peer;
// All operations (including stats and destroy) are serialized by the caller. No pointers from
// the caller are retained. Destroy joins capture/transport before freeing state.
// Native exceptions never cross this ABI. Errors contain no SDP or credentials.
MDR_API uint32_t mdr_abi_version(void);
typedef struct mdr_ice_server { const char* url; const char* username; const char* credential; } mdr_ice_server;
// Up to eight URLs, each string <=512 bytes. Copies all strings before return.
MDR_API int mdr_configure_ice(mdr_peer* peer, const mdr_ice_server* servers, size_t count,
    int force_relay, char* error, size_t error_size);
// source: 0 = desktop loopback, 1 = synthetic stereo probe, 2 = receive-only test,
// 3 = phone-microphone return into the explicit endpoint (initially muted),
// 4 = synthetic stock-Opus test sender (no physical capture),
// 7 = headless duplex contract (synthetic desktop and decoded return sink).
MDR_API int mdr_create(int source, const char* endpoint_id, mdr_peer** out, char* error, size_t error_size);
// Explicit remote route policy, selected before creating the native peer.
// Renomination takes effect only when both SDK descriptions advertise it.
MDR_API int mdr_create_configured(int source, const char* endpoint_id, int enable_renomination, int continuous_gathering,
    mdr_peer** out, char* error, size_t error_size);
// Paired duplex: desktop capture/probe plus return into the explicit cable.
// Empty capture ID pins the default at session start. Render ID is mandatory.
MDR_API int mdr_create_duplex(int probe, const char* capture_endpoint_id, const char* render_endpoint_id,
    mdr_peer** out, char* error, size_t error_size);
MDR_API int mdr_create_duplex_configured(int probe, const char* capture_endpoint_id, const char* render_endpoint_id,
    int enable_renomination, int continuous_gathering, mdr_peer** out, char* error, size_t error_size);
MDR_API int mdr_offer(mdr_peer* peer, char* sdp, size_t capacity, char* error, size_t error_size);
// Negotiated initial trickle only. Returns after local description creation;
// candidates continue gathering on the same peer. Never authorizes audio.
MDR_API int mdr_trickle_offer(mdr_peer* peer, char* sdp, size_t capacity, char* error, size_t error_size);
MDR_API int mdr_local_ice(mdr_peer* peer, char* sdp, size_t capacity, int* complete, char* error, size_t error_size);
MDR_API int mdr_add_ice(mdr_peer* peer, const char* mid, int index, const char* ufrag,
    const char* candidate, char* error, size_t error_size);
MDR_API int mdr_remove_ice(mdr_peer* peer, const char* mid, int index, const char* ufrag,
    const char* candidate, char* error, size_t error_size);
// Existing, answered peer only. New ICE credentials/candidates, same audio tracks.
MDR_API int mdr_restart_offer(mdr_peer* peer, char* sdp, size_t capacity, char* error, size_t error_size);
MDR_API int mdr_answer(mdr_peer* peer, const char* sdp, char* error, size_t error_size);
// Only microphone/duplex sources after a valid answer. Waits <=5s for queue reset/applied
// state, fails on endpoint loss. No default output fallback.
MDR_API int mdr_microphone_mute(mdr_peer* peer, int muted, char* error, size_t error_size);
// Test receiver: accept an offer and produce the complete answer, without devices.
MDR_API int mdr_test_accept(mdr_peer* peer, const char* offer, char* answer, size_t capacity, char* error, size_t error_size);
MDR_API int mdr_test_send_accept(mdr_peer* peer, const char* offer, char* answer, size_t capacity, char* error, size_t error_size);
MDR_API int mdr_test_duplex_accept(mdr_peer* peer, const char* offer, char* answer, size_t capacity, char* error, size_t error_size);
// Bounded diagnostics JSON: excludes addresses, candidates, SDP, and tokens.
MDR_API int mdr_status(mdr_peer* peer, char* json, size_t capacity);
MDR_API void mdr_destroy(mdr_peer* peer);
#ifdef __cplusplus
}
#endif
#endif
