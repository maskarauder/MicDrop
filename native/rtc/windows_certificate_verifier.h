#pragma once
#include <windows.h>
#include <wincrypt.h>
#include <cstdint>
#include <memory>
#include <mutex>
#include "rtc_base/ssl_certificate.h"

namespace micdrop {

// Counts and a Windows error code only; never certificate names, URLs or DER.
struct TLSVerificationSnapshot {
  uint32_t checks = 0, failures = 0, last_error = 0;
};

class TLSVerificationDiagnostics {
 public:
  bool Record(DWORD error) {
    std::lock_guard lock(mutex_);
    ++value_.checks;
    if (error) ++value_.failures;
    value_.last_error = error;
    return error == ERROR_SUCCESS;
  }
  TLSVerificationSnapshot Snapshot() const {
    std::lock_guard lock(mutex_);
    return value_;
  }
 private:
  mutable std::mutex mutex_;
  TLSVerificationSnapshot value_;
};

// WebRTC's built-in TURN/TLS anchors do not include every public CA. Use the
// current Windows account's trust store when that validation needs a fallback.
// WebRTC still checks the TURN hostname after this chain callback succeeds.
class WindowsCertificateVerifier final : public webrtc::SSLCertificateVerifier {
 public:
  explicit WindowsCertificateVerifier(std::shared_ptr<TLSVerificationDiagnostics> diagnostics,
      HCERTCHAINENGINE engine = HCCE_CURRENT_USER)
      : diagnostics_(std::move(diagnostics)), engine_(engine) {}
  bool VerifyChain(const webrtc::SSLCertChain& chain) override;
  bool Verify(const webrtc::SSLCertificate& certificate) override;
 private:
  // Non-default engines are used only by offline tests, and must outlive us.
  std::shared_ptr<TLSVerificationDiagnostics> diagnostics_;
  HCERTCHAINENGINE engine_;
};

}  // namespace micdrop
