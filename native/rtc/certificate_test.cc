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
  HCERTSTORE store = CertOpenStore(CERT_STORE_PROV_MEMORY, 0, 0, 0, nullptr);
  HCERTCHAINENGINE engine = nullptr;
  bool Initialize(bool trusted) {
    if (!store) return false;
    if (trusted) {
      auto root = webrtc::SSLCertificate::FromPEMString(micdrop::test::kRoot);
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
  ~TestTrust() {
    if (engine) CertFreeCertificateChainEngine(engine);
    if (store) CertCloseStore(store, 0);
  }
};
#else
struct TestTrust {
  micdrop::PosixCertificateVerifier::RootList roots;
  bool Initialize(bool trusted) {
    roots.clear();
    if (trusted) {
      auto root = webrtc::SSLCertificate::FromPEMString(micdrop::test::kRoot);
      if (!root) return false;
      webrtc::Buffer der;
      root->ToDER(&der);
      if (!der.size()) return false;
      roots.emplace_back(der.data(), der.data() + der.size());
    }
    return true;
  }
  auto MakeVerifier(std::shared_ptr<micdrop::TLSVerificationDiagnostics> diagnostics) const {
    return micdrop::PosixCertificateVerifier(std::move(diagnostics), roots);
  }
};
#endif
}  // namespace

int main() {
  using namespace micdrop::test;
  try {
    Require(webrtc::InitializeSSL(), "WebRTC TLS initialization failed");
    TestTrust trusted, untrusted;
    Require(trusted.Initialize(true) && untrusted.Initialize(false), "Test chain engine creation failed");
    auto diagnostics = std::make_shared<micdrop::TLSVerificationDiagnostics>();
    auto verifier = trusted.MakeVerifier(diagnostics);
    auto rejecting = untrusted.MakeVerifier(diagnostics);
    const auto server = Certificates({kServer, kIntermediate});
    Require(verifier.VerifyChain(server), "Trusted server chain rejected");
    // A peer-provided root is not a trust anchor, even if self-signed correctly.
    Require(!rejecting.VerifyChain(Certificates({kServer, kIntermediate, kRoot})), "Untrusted supplied root accepted");
    Require(!verifier.VerifyChain(Certificates({kClientOnly, kIntermediate})), "Client-only EKU accepted for a server");
    Require(!verifier.VerifyChain(Certificates({kExpired, kIntermediate})), "Expired server certificate accepted");
    Require(!verifier.VerifyChain(Certificates({})), "Empty certificate chain accepted");
    // Use a fresh engine: the positive test may have cached its intermediate.
    TestTrust missing_intermediate;
    Require(missing_intermediate.Initialize(true), "Missing-intermediate engine creation failed");
    auto incomplete = missing_intermediate.MakeVerifier(diagnostics);
    Require(!incomplete.Verify(server.Get(0)), "Incomplete chain accepted without an intermediate");
    // Success after failures must not retain an old error code.
    Require(verifier.VerifyChain(server), "Valid chain did not recover after rejection");
    const auto stats = diagnostics->Snapshot();
    Require(stats.checks == 7 && stats.failures == 5 && stats.last_error == 0, "TLS diagnostics incorrect");
    std::puts("OS trust accepted a server chain and rejected untrusted roots, wrong EKU, expiry, empty and incomplete chains");
  } catch (const std::exception& error) {
    std::puts(error.what());
    return 1;
  }
  return 0;
}
