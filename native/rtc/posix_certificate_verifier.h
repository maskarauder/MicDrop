// SPDX-License-Identifier: MPL-2.0
#pragma once
#include <cstdint>
#include <memory>
#include <mutex>
#include <optional>
#include <vector>
#include "rtc_base/ssl_certificate.h"
#include "tls_diagnostics.h"

#if !defined(__APPLE__)
typedef struct x509_store_st X509_STORE;
#endif

namespace micdrop {

// Validates TURN/TLS server certificate chains against OS trust policies
// (SecTrust + SecPolicyCreateSSL on macOS, BoringSSL + system CA bundle on
// Linux, or an isolated in-memory anchor list in offline unit tests).
// WebRTC checks the TURN hostname separately after this chain callback succeeds.
class PosixCertificateVerifier final : public webrtc::SSLCertificateVerifier {
 public:
  using RootList = std::vector<std::vector<uint8_t>>;

  explicit PosixCertificateVerifier(
      std::shared_ptr<TLSVerificationDiagnostics> diagnostics,
      std::optional<RootList> exclusive_roots = std::nullopt,
      std::optional<int64_t> verify_unix_seconds = std::nullopt);
  ~PosixCertificateVerifier() override;

  PosixCertificateVerifier(const PosixCertificateVerifier&) = delete;
  PosixCertificateVerifier& operator=(const PosixCertificateVerifier&) = delete;

  bool VerifyChain(const webrtc::SSLCertChain& chain) override;
  bool Verify(const webrtc::SSLCertificate& certificate) override;

 private:
#if !defined(__APPLE__)
  X509_STORE* EnsureTrustStore();
  std::mutex store_mutex_;
  bool store_initialized_ = false;
  X509_STORE* store_ = nullptr;
#endif

  std::shared_ptr<TLSVerificationDiagnostics> diagnostics_;
  std::optional<RootList> exclusive_roots_;
  std::optional<int64_t> verify_unix_seconds_;
};

}  // namespace micdrop
