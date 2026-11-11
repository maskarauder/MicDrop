// SPDX-License-Identifier: MPL-2.0
#pragma once
#include <cstdint>
#include <memory>
#include <mutex>
#include <optional>
#include <vector>
#include "rtc_base/ssl_certificate.h"
#include "tls_diagnostics.h"

typedef struct x509_store_st X509_STORE;

namespace micdrop {

// Validates TURN/TLS server certificate chains against OS trust anchors on Linux
// and macOS (or an isolated in-memory anchor list in offline unit tests).
// WebRTC checks the TURN hostname separately after this chain callback succeeds.
class PosixCertificateVerifier final : public webrtc::SSLCertificateVerifier {
 public:
  using RootList = std::vector<std::vector<uint8_t>>;

  explicit PosixCertificateVerifier(
      std::shared_ptr<TLSVerificationDiagnostics> diagnostics,
      std::optional<RootList> exclusive_roots = std::nullopt);
  ~PosixCertificateVerifier() override;

  PosixCertificateVerifier(const PosixCertificateVerifier&) = delete;
  PosixCertificateVerifier& operator=(const PosixCertificateVerifier&) = delete;

  bool VerifyChain(const webrtc::SSLCertChain& chain) override;
  bool Verify(const webrtc::SSLCertificate& certificate) override;

 private:
  X509_STORE* EnsureTrustStore();

  std::shared_ptr<TLSVerificationDiagnostics> diagnostics_;
  std::optional<RootList> exclusive_roots_;
  std::mutex store_mutex_;
  bool store_initialized_ = false;
  X509_STORE* store_ = nullptr;
};

}  // namespace micdrop
