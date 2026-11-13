#ifdef _WIN32
#include "windows_certificate_verifier.h"
#else
#include "posix_certificate_verifier.h"
#endif
#include "certificate_test_fixtures.h"
#include <cstdio>
#include <initializer_list>
#include <stdexcept>
#include <vector>
#include "rtc_base/buffer.h"
#include "rtc_base/ssl_adapter.h"

namespace {
void Require(bool value, const char* description) {
  if (!value) throw std::runtime_error(description);
}

webrtc::SSLCertChain Certificates(std::initializer_list<const char*> pems) {
  std::vector<std::unique_ptr<webrtc::SSLCertificate>> certificates;
  for (const auto* pem : pems) {
    auto certificate = webrtc::SSLCertificate::FromPEMString(pem);
    Require(certificate != nullptr, "Could not parse test certificate");
    certificates.push_back(std::move(certificate));
  }
  return webrtc::SSLCertChain(std::move(certificates));
}

#ifdef _WIN32
// An exclusive, in-memory engine gives the positive test a trust anchor without
// adding a test CA to the runner's user or machine root store.
struct TestTrust {
  static constexpr const char* kRootPEM = micdrop::test::kRoot;
  static constexpr const char* kIntermediatePEM = micdrop::test::kIntermediate;
  static constexpr const char* kServerPEM = micdrop::test::kServer;
  static constexpr const char* kClientOnlyPEM = micdrop::test::kClientOnly;
  static constexpr const char* kExpiredPEM = micdrop::test::kExpired;

  HCERTSTORE store = CertOpenStore(CERT_STORE_PROV_MEMORY, 0, 0, 0, nullptr);
  HCERTCHAINENGINE engine = nullptr;
  bool Initialize(bool trusted) {
    if (!store) return false;
    if (trusted) {
      auto root = webrtc::SSLCertificate::FromPEMString(kRootPEM);
      if (!root) return false;
      webrtc::Buffer der;
      root->ToDER(&der);
      if (!CertAddEncodedCertificateToStore(store, X509_ASN_ENCODING, der.data(),
          static_cast<DWORD>(der.size()), CERT_STORE_ADD_ALWAYS, nullptr)) return false;
    }
    CERT_CHAIN_ENGINE_CONFIG config{};
    config.cbSize = sizeof(config);
    config.hExclusiveRoot = store;
    config.dwFlags = CERT_CHAIN_CACHE_ONLY_URL_RETRIEVAL | CERT_CHAIN_DISABLE_AIA;
    return CertCreateCertificateChainEngine(&config, &engine) != FALSE;
  }
  auto MakeVerifier(std::shared_ptr<micdrop::TLSVerificationDiagnostics> diagnostics) const {
    return micdrop::WindowsCertificateVerifier(std::move(diagnostics), engine);
  }
  static auto MakeSystemVerifier(std::shared_ptr<micdrop::TLSVerificationDiagnostics> diagnostics) {
    return micdrop::WindowsCertificateVerifier(std::move(diagnostics));
  }
  ~TestTrust() {
    if (engine) CertFreeCertificateChainEngine(engine);
    if (store) CertCloseStore(store, 0);
  }
};
#else
struct TestTrust {
  static constexpr const char* kRootPEM = micdrop::test::kShortRoot;
  static constexpr const char* kIntermediatePEM = micdrop::test::kShortIntermediate;
  static constexpr const char* kServerPEM = micdrop::test::kShortServer;
  static constexpr const char* kClientOnlyPEM = micdrop::test::kShortClientOnly;
  static constexpr const char* kExpiredPEM = micdrop::test::kShortExpired;

  micdrop::PosixCertificateVerifier::RootList roots;
  bool Initialize(bool trusted) {
    roots.clear();
    if (trusted) {
      auto root = webrtc::SSLCertificate::FromPEMString(kRootPEM);
      if (!root) return false;
      webrtc::Buffer der;
      root->ToDER(&der);
      if (!der.size()) return false;
      roots.emplace_back(der.data(), der.data() + der.size());
    }
    return true;
  }
  auto MakeVerifier(std::shared_ptr<micdrop::TLSVerificationDiagnostics> diagnostics) const {
    return micdrop::PosixCertificateVerifier(
        std::move(diagnostics), roots, micdrop::test::kShortVerifyUnixSeconds);
  }
  static auto MakeSystemVerifier(std::shared_ptr<micdrop::TLSVerificationDiagnostics> diagnostics) {
    return micdrop::PosixCertificateVerifier(std::move(diagnostics));
  }
};
#endif
}  // namespace

int main() {
  try {
    Require(webrtc::InitializeSSL(), "WebRTC TLS initialization failed");
    TestTrust trusted, untrusted;
    Require(trusted.Initialize(true) && untrusted.Initialize(false), "Test chain engine creation failed");
    auto diagnostics = std::make_shared<micdrop::TLSVerificationDiagnostics>();
    auto verifier = trusted.MakeVerifier(diagnostics);
    auto rejecting = untrusted.MakeVerifier(diagnostics);
    auto system_verifier = TestTrust::MakeSystemVerifier(diagnostics);
    const auto server = Certificates({TestTrust::kServerPEM, TestTrust::kIntermediatePEM});
    const auto supplied_root_chain =
        Certificates({TestTrust::kServerPEM, TestTrust::kIntermediatePEM, TestTrust::kRootPEM});
    Require(verifier.VerifyChain(server), "Trusted server chain rejected");
    // A peer-provided root is not a trust anchor, even if self-signed correctly.
    Require(!rejecting.VerifyChain(supplied_root_chain), "Untrusted supplied root accepted");
    Require(!system_verifier.VerifyChain(supplied_root_chain),
            "Live OS trust store accepted an unanchored test root");
#ifndef _WIN32
    // On macOS, also verify live Keychain SecTrust (exclusive_roots == nullopt)
    // rejects an unanchored chain when evaluated inside the leaf's validity window,
    // and enforces Apple's 825-day TLS leaf lifetime policy on legacy 80-year leaves.
    micdrop::PosixCertificateVerifier live_store_at_fixture_time(
        diagnostics, std::nullopt, micdrop::test::kShortVerifyUnixSeconds);
    Require(!live_store_at_fixture_time.VerifyChain(supplied_root_chain),
            "Live POSIX trust store accepted unanchored chain inside validity window");
    Require(!live_store_at_fixture_time.Verify(server.Get(0)),
            "Live POSIX trust store accepted incomplete leaf chain");
#ifdef __APPLE__
    micdrop::PosixCertificateVerifier::RootList legacy_roots;
    auto legacy_root = webrtc::SSLCertificate::FromPEMString(micdrop::test::kRoot);
    Require(legacy_root != nullptr, "Could not parse legacy root");
    webrtc::Buffer legacy_der;
    legacy_root->ToDER(&legacy_der);
    legacy_roots.emplace_back(legacy_der.data(), legacy_der.data() + legacy_der.size());
    micdrop::PosixCertificateVerifier apple_policy_verifier(
        diagnostics, legacy_roots, micdrop::test::kShortVerifyUnixSeconds);
    Require(!apple_policy_verifier.VerifyChain(
                Certificates({micdrop::test::kServer, micdrop::test::kIntermediate})),
            "macOS SecPolicyCreateSSL accepted an 80-year leaf certificate");
#endif
#endif
    Require(!verifier.VerifyChain(
                Certificates({TestTrust::kClientOnlyPEM, TestTrust::kIntermediatePEM})),
            "Client-only EKU accepted for a server");
    Require(!verifier.VerifyChain(
                Certificates({TestTrust::kExpiredPEM, TestTrust::kIntermediatePEM})),
            "Expired server certificate accepted");
    Require(!verifier.VerifyChain(Certificates({})), "Empty certificate chain accepted");
    // Use a fresh engine: the positive test may have cached its intermediate.
    TestTrust missing_intermediate;
    Require(missing_intermediate.Initialize(true), "Missing-intermediate engine creation failed");
    auto incomplete = missing_intermediate.MakeVerifier(diagnostics);
    Require(!incomplete.Verify(server.Get(0)), "Incomplete chain accepted without an intermediate");
    // Success after failures must not retain an old error code.
    Require(verifier.VerifyChain(server), "Valid chain did not recover after rejection");
    const auto stats = diagnostics->Snapshot();
#ifdef _WIN32
    constexpr uint64_t kExpectedChecks = 8;
    constexpr uint64_t kExpectedFailures = 6;
#elif defined(__APPLE__)
    constexpr uint64_t kExpectedChecks = 11;
    constexpr uint64_t kExpectedFailures = 9;
#else
    constexpr uint64_t kExpectedChecks = 10;
    constexpr uint64_t kExpectedFailures = 8;
#endif
    Require(stats.checks == kExpectedChecks &&
                stats.failures == kExpectedFailures &&
                stats.last_error == 0,
            "TLS diagnostics incorrect");
    std::puts("OS trust accepted a server chain and rejected untrusted roots, wrong EKU, expiry, empty and incomplete chains");
  } catch (const std::exception& error) {
    std::puts(error.what());
    return 1;
  }
  return 0;
}
