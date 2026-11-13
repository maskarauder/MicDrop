#pragma once
#include <windows.h>
#include <wincrypt.h>
#include <cstdint>
#include <memory>
#include "rtc_base/ssl_certificate.h"
#include "tls_diagnostics.h"

namespace micdrop {

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
