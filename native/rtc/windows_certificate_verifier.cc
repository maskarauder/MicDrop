#include "windows_certificate_verifier.h"
#include <new>
#include "rtc_base/buffer.h"

namespace micdrop {
namespace {
DWORD FailureCode() {
  const auto error = GetLastError();
  return error ? error : ERROR_INVALID_DATA;
}
struct Store {
  HCERTSTORE value = CertOpenStore(CERT_STORE_PROV_MEMORY, 0, 0, 0, nullptr);
  ~Store() { if (value) CertCloseStore(value, 0); }
};
struct Certificate {
  PCCERT_CONTEXT value = nullptr;
  ~Certificate() { if (value) CertFreeCertificateContext(value); }
};
struct Chain {
  PCCERT_CHAIN_CONTEXT value = nullptr;
  ~Chain() { if (value) CertFreeCertificateChain(value); }
};

DWORD VerifyServerChain(const webrtc::SSLCertChain& certificates, HCERTCHAINENGINE engine) {
  if (!certificates.GetSize() || certificates.GetSize() > 16) return ERROR_INVALID_DATA;
  Store intermediates;
  if (!intermediates.value) return FailureCode();
  Certificate leaf;
  size_t total_bytes = 0;
  for (size_t i = 0; i < certificates.GetSize(); ++i) {
    webrtc::Buffer der;
    certificates.Get(i).ToDER(&der);
    if (!der.size() || der.size() > 1024 * 1024 - total_bytes) return ERROR_INVALID_DATA;
    total_bytes += der.size();
    if (i == 0) {
      leaf.value = CertCreateCertificateContext(X509_ASN_ENCODING, der.data(), static_cast<DWORD>(der.size()));
      if (!leaf.value) return FailureCode();
    } else if (!CertAddEncodedCertificateToStore(intermediates.value, X509_ASN_ENCODING,
        der.data(), static_cast<DWORD>(der.size()), CERT_STORE_ADD_ALWAYS, nullptr)) {
      return FailureCode();
    }
  }
  // Peer-supplied intermediates (including any supplied root) are only chain
  // building hints. They are never installed into a Windows trusted-root store.
  char server_auth[] = szOID_PKIX_KP_SERVER_AUTH;
  char* usages[] = {server_auth};
  CERT_CHAIN_PARA parameters{};
  parameters.cbSize = sizeof(parameters);
  parameters.RequestedUsage.dwType = USAGE_MATCH_TYPE_AND;
  parameters.RequestedUsage.Usage.cUsageIdentifier = 1;
  parameters.RequestedUsage.Usage.rgpszUsageIdentifier = usages;
  parameters.dwUrlRetrievalTimeout = 2000;
  Chain chain;
  if (!CertGetCertificateChain(engine, leaf.value, nullptr, intermediates.value,
      &parameters, 0, nullptr, &chain.value)) return FailureCode();

  SSL_EXTRA_CERT_CHAIN_POLICY_PARA ssl{};
  ssl.cbSize = sizeof(ssl);
  ssl.dwAuthType = AUTHTYPE_SERVER;
  // This API callback has no hostname. WebRTC's SSLPostConnectionCheck verifies
  // the original TURN URL's hostname separately, even after a custom verifier.
  CERT_CHAIN_POLICY_PARA policy{};
  policy.cbSize = sizeof(policy);
  policy.pvExtraPolicyPara = &ssl;
  CERT_CHAIN_POLICY_STATUS status{};
  status.cbSize = sizeof(status);
  if (!CertVerifyCertificateChainPolicy(CERT_CHAIN_POLICY_SSL, chain.value, &policy, &status))
    return FailureCode();
  return status.dwError;
}
}  // namespace

bool WindowsCertificateVerifier::VerifyChain(const webrtc::SSLCertChain& chain) {
  DWORD error = ERROR_INVALID_DATA;
  try {
    error = VerifyServerChain(chain, engine_);
  } catch (const std::bad_alloc&) {
    error = ERROR_NOT_ENOUGH_MEMORY;
  } catch (...) {
    // Never let a malformed certificate or allocation failure escape WebRTC's
    // networking callback, and never turn a verification failure into success.
  }
  return diagnostics_->Record(error);
}

bool WindowsCertificateVerifier::Verify(const webrtc::SSLCertificate& certificate) {
  try {
    return VerifyChain(webrtc::SSLCertChain(certificate.Clone()));
  } catch (...) {
    return diagnostics_->Record(ERROR_INVALID_DATA);
  }
}
}  // namespace micdrop
