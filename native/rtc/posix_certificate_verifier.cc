// SPDX-License-Identifier: MPL-2.0
#include "posix_certificate_verifier.h"

#include <ctime>
#include <new>

#if !defined(__APPLE__)
#include <sys/stat.h>
#endif

#include <openssl/err.h>
#include <openssl/stack.h>
#include <openssl/x509.h>

#if defined(__APPLE__)
#include <CoreFoundation/CoreFoundation.h>
#include <Security/Security.h>
#endif

#include "rtc_base/buffer.h"

namespace micdrop {
namespace {

constexpr uint32_t kErrorInvalidData = 13;
constexpr uint32_t kErrorOutOfMemory = 14;
constexpr uint32_t kErrorTrustStoreUnavailable = 1359;

struct ErrCleaner {
  ~ErrCleaner() { ERR_clear_error(); }
};

struct X509Deleter {
  void operator()(X509* cert) const {
    if (cert) X509_free(cert);
  }
};
using ScopedX509 = std::unique_ptr<X509, X509Deleter>;

ScopedX509 ParseDER(const uint8_t* data, size_t size) {
  if (!data || size == 0 || size > 1024 * 1024) return nullptr;
  const uint8_t* ptr = data;
  return ScopedX509(d2i_X509(nullptr, &ptr, static_cast<long>(size)));
}

#if defined(__APPLE__)
template <typename T>
struct CFGuard {
  T ref = nullptr;
  explicit CFGuard(T value = nullptr) : ref(value) {}
  ~CFGuard() {
    if (ref) CFRelease(ref);
  }
  CFGuard(const CFGuard&) = delete;
  CFGuard& operator=(const CFGuard&) = delete;
};

uint32_t VerifyServerChainMacOS(
    const webrtc::SSLCertChain& certificates,
    const std::optional<PosixCertificateVerifier::RootList>& exclusive_roots,
    const std::optional<int64_t>& verify_unix_seconds) {
  ErrCleaner cleaner;
  if (certificates.GetSize() == 0 || certificates.GetSize() > 16) {
    return kErrorInvalidData;
  }

  CFGuard<CFMutableArrayRef> cert_chain(
      CFArrayCreateMutable(kCFAllocatorDefault, 0, &kCFTypeArrayCallBacks));
  if (!cert_chain.ref) return kErrorOutOfMemory;

  size_t total_bytes = 0;
  for (size_t i = 0; i < certificates.GetSize(); ++i) {
    webrtc::Buffer der;
    certificates.Get(i).ToDER(&der);
    if (der.size() == 0 || der.size() > 1024 * 1024 - total_bytes) {
      return kErrorInvalidData;
    }
    total_bytes += der.size();

    ScopedX509 parsed = ParseDER(der.data(), der.size());
    if (!parsed) return kErrorInvalidData;
    if (i == 0 && (X509_get_extended_key_usage(parsed.get()) & XKU_SSL_SERVER) == 0) {
      return static_cast<uint32_t>(X509_V_ERR_INVALID_PURPOSE);
    }

    CFGuard<CFDataRef> cf_der(
        CFDataCreate(kCFAllocatorDefault, der.data(), static_cast<CFIndex>(der.size())));
    if (!cf_der.ref) return kErrorOutOfMemory;
    CFGuard<SecCertificateRef> sec_cert(
        SecCertificateCreateWithData(kCFAllocatorDefault, cf_der.ref));
    if (!sec_cert.ref) return kErrorInvalidData;
    // Index 0 is the peer leaf; subsequent certificates are untrusted chain-building
    // hints and are never added to SecTrust anchor certificates.
    CFArrayAppendValue(cert_chain.ref, sec_cert.ref);
  }

  // This callback receives no hostname. WebRTC's SSLPostConnectionCheck verifies
  // the original TURN URL hostname separately after chain validation succeeds.
  CFGuard<SecPolicyRef> policy(SecPolicyCreateSSL(/*server=*/true, /*hostname=*/nullptr));
  if (!policy.ref) return kErrorOutOfMemory;

  SecTrustRef raw_trust = nullptr;
  const OSStatus create_status =
      SecTrustCreateWithCertificates(cert_chain.ref, policy.ref, &raw_trust);
  CFGuard<SecTrustRef> trust(raw_trust);
  if (create_status != errSecSuccess || !trust.ref) {
    return create_status != errSecSuccess
               ? static_cast<uint32_t>(static_cast<int32_t>(create_status))
               : kErrorInvalidData;
  }

  // Never allow synchronous AIA or revocation network downloads on WebRTC's
  // network thread; missing intermediates must be supplied by the peer handshake.
  if (SecTrustSetNetworkFetchAllowed(trust.ref, false) != errSecSuccess) {
    return kErrorTrustStoreUnavailable;
  }

  // In production (exclusive_roots == std::nullopt), leave SecTrust's default
  // anchor configuration intact so macOS evaluates system roots alongside user
  // and admin Keychain trust settings (including per-leaf or per-intermediate
  // "Never Trust" overrides).
  if (exclusive_roots.has_value()) {
    CFGuard<CFMutableArrayRef> anchors(
        CFArrayCreateMutable(kCFAllocatorDefault, 0, &kCFTypeArrayCallBacks));
    if (!anchors.ref) return kErrorOutOfMemory;
    for (const auto& root_der : *exclusive_roots) {
      if (root_der.empty() || root_der.size() > 1024 * 1024) return kErrorInvalidData;
      CFGuard<CFDataRef> cf_root(
          CFDataCreate(kCFAllocatorDefault, root_der.data(), static_cast<CFIndex>(root_der.size())));
      if (!cf_root.ref) return kErrorOutOfMemory;
      CFGuard<SecCertificateRef> sec_root(
          SecCertificateCreateWithData(kCFAllocatorDefault, cf_root.ref));
      if (!sec_root.ref) return kErrorInvalidData;
      CFArrayAppendValue(anchors.ref, sec_root.ref);
    }
    if (SecTrustSetAnchorCertificates(trust.ref, anchors.ref) != errSecSuccess ||
        SecTrustSetAnchorCertificatesOnly(trust.ref, true) != errSecSuccess) {
      return kErrorTrustStoreUnavailable;
    }
  }

  if (verify_unix_seconds.has_value()) {
    const CFAbsoluteTime cf_time =
        static_cast<CFAbsoluteTime>(*verify_unix_seconds) - kCFAbsoluteTimeIntervalSince1970;
    CFGuard<CFDateRef> verify_date(CFDateCreate(kCFAllocatorDefault, cf_time));
    if (!verify_date.ref ||
        SecTrustSetVerifyDate(trust.ref, verify_date.ref) != errSecSuccess) {
      return kErrorInvalidData;
    }
  }

  CFErrorRef raw_error = nullptr;
  const bool trusted = SecTrustEvaluateWithError(trust.ref, &raw_error);
  CFGuard<CFErrorRef> eval_error(raw_error);
  if (!trusted) {
    const CFIndex code = eval_error.ref ? CFErrorGetCode(eval_error.ref) : 0;
    return code != 0 ? static_cast<uint32_t>(static_cast<int32_t>(code)) : kErrorInvalidData;
  }

  CFGuard<CFArrayRef> evaluated_chain(SecTrustCopyCertificateChain(trust.ref));
  if (!evaluated_chain.ref || CFArrayGetCount(evaluated_chain.ref) == 0) {
    return kErrorInvalidData;
  }
  const CFIndex chain_count = CFArrayGetCount(evaluated_chain.ref);
  for (CFIndex i = 0; i < chain_count; ++i) {
    const void* item = CFArrayGetValueAtIndex(evaluated_chain.ref, i);
    if (!item) return kErrorInvalidData;
    auto cert_ref = reinterpret_cast<SecCertificateRef>(const_cast<void*>(item));
    CFGuard<CFDataRef> cert_der(SecCertificateCopyData(cert_ref));
    if (!cert_der.ref) return kErrorInvalidData;
    const UInt8* bytes = CFDataGetBytePtr(cert_der.ref);
    const CFIndex len = CFDataGetLength(cert_der.ref);
    ScopedX509 x509_cert =
        (bytes && len > 0) ? ParseDER(bytes, static_cast<size_t>(len)) : nullptr;
    if (!x509_cert) return kErrorInvalidData;
    const uint32_t eku = X509_get_extended_key_usage(x509_cert.get());
    const uint32_t allowed = (i == 0) ? XKU_SSL_SERVER : (XKU_SSL_SERVER | XKU_ANYEKU);
    if ((eku & allowed) == 0) {
      return static_cast<uint32_t>(X509_V_ERR_INVALID_PURPOSE);
    }
  }

  return 0;
}
#else
struct X509StackDeleter {
  void operator()(STACK_OF(X509)* stack) const {
    if (stack) sk_X509_pop_free(stack, X509_free);
  }
};
using ScopedX509Stack = std::unique_ptr<STACK_OF(X509), X509StackDeleter>;

struct StoreDeleter {
  void operator()(X509_STORE* store) const {
    if (store) X509_STORE_free(store);
  }
};
using ScopedStore = std::unique_ptr<X509_STORE, StoreDeleter>;

struct StoreCtxDeleter {
  void operator()(X509_STORE_CTX* ctx) const {
    if (ctx) X509_STORE_CTX_free(ctx);
  }
};
using ScopedStoreCtx = std::unique_ptr<X509_STORE_CTX, StoreCtxDeleter>;

bool FileExists(const char* path) {
  struct stat st{};
  return path && ::stat(path, &st) == 0 && S_ISREG(st.st_mode);
}

bool DirExists(const char* path) {
  struct stat st{};
  return path && ::stat(path, &st) == 0 && S_ISDIR(st.st_mode);
}

bool LoadSystemRootsLinux(X509_STORE* store) {
  static constexpr const char* kBundleCandidates[] = {
      "/etc/ssl/certs/ca-certificates.crt",
      "/etc/pki/tls/certs/ca-bundle.crt",
      "/etc/ssl/ca-bundle.pem",
      "/etc/pki/ca-trust/extracted/pem/tls-ca-bundle.pem",
      "/etc/ssl/cert.pem",
  };
  bool loaded = false;
  for (const char* bundle : kBundleCandidates) {
    if (FileExists(bundle) && X509_STORE_load_locations(store, bundle, nullptr) == 1) {
      loaded = true;
      break;
    }
    ERR_clear_error();
  }
  static constexpr const char* kDirCandidates[] = {
      "/etc/ssl/certs",
      "/etc/pki/tls/certs",
  };
  for (const char* dir : kDirCandidates) {
    if (DirExists(dir) && X509_STORE_load_locations(store, nullptr, dir) == 1) {
      loaded = true;
      break;
    }
    ERR_clear_error();
  }
  return loaded;
}

uint32_t VerifyServerChainLinux(const webrtc::SSLCertChain& certificates,
                                X509_STORE* store,
                                const std::optional<int64_t>& verify_unix_seconds) {
  ErrCleaner cleaner;
  if (!store) return kErrorTrustStoreUnavailable;
  if (certificates.GetSize() == 0 || certificates.GetSize() > 16) return kErrorInvalidData;

  ScopedX509 leaf;
  ScopedX509Stack untrusted(sk_X509_new_null());
  if (!untrusted) return kErrorOutOfMemory;

  size_t total_bytes = 0;
  for (size_t i = 0; i < certificates.GetSize(); ++i) {
    webrtc::Buffer der;
    certificates.Get(i).ToDER(&der);
    if (der.size() == 0 || der.size() > 1024 * 1024 - total_bytes) return kErrorInvalidData;
    total_bytes += der.size();
    ScopedX509 cert = ParseDER(der.data(), der.size());
    if (!cert) return kErrorInvalidData;
    if (i == 0) {
      leaf = std::move(cert);
    } else {
      // Peer-supplied intermediates (including any supplied root) are strictly
      // untrusted chain-building hints and never added as trust anchors.
      if (!sk_X509_push(untrusted.get(), cert.get())) return kErrorOutOfMemory;
      cert.release();
    }
  }

  // Enforce server authentication EKU when an Extended Key Usage extension is present.
  // X509_get_extended_key_usage returns UINT32_MAX when no EKU extension exists.
  const uint32_t eku = X509_get_extended_key_usage(leaf.get());
  if ((eku & XKU_SSL_SERVER) == 0) {
    return static_cast<uint32_t>(X509_V_ERR_INVALID_PURPOSE);
  }

  ScopedStoreCtx ctx(X509_STORE_CTX_new());
  if (!ctx) return kErrorOutOfMemory;
  if (X509_STORE_CTX_init(ctx.get(), store, leaf.get(), untrusted.get()) != 1) {
    return kErrorInvalidData;
  }

  X509_VERIFY_PARAM* param = X509_STORE_CTX_get0_param(ctx.get());
  if (!param ||
      X509_VERIFY_PARAM_set_purpose(param, X509_PURPOSE_SSL_SERVER) != 1 ||
      X509_VERIFY_PARAM_set_trust(param, X509_TRUST_SSL_SERVER) != 1) {
    return kErrorInvalidData;
  }
  if (verify_unix_seconds.has_value()) {
    X509_VERIFY_PARAM_set_time(param, static_cast<time_t>(*verify_unix_seconds));
  }

  if (X509_verify_cert(ctx.get()) == 1) {
    return 0;
  }
  const int verify_error = X509_STORE_CTX_get_error(ctx.get());
  return verify_error > 0 ? static_cast<uint32_t>(verify_error) : kErrorInvalidData;
}
#endif

}  // namespace

PosixCertificateVerifier::PosixCertificateVerifier(
    std::shared_ptr<TLSVerificationDiagnostics> diagnostics,
    std::optional<RootList> exclusive_roots,
    std::optional<int64_t> verify_unix_seconds)
    : diagnostics_(std::move(diagnostics)),
      exclusive_roots_(std::move(exclusive_roots)),
      verify_unix_seconds_(verify_unix_seconds) {}

PosixCertificateVerifier::~PosixCertificateVerifier() {
#if !defined(__APPLE__)
  if (store_) {
    X509_STORE_free(store_);
    store_ = nullptr;
  }
#endif
}

#if !defined(__APPLE__)
X509_STORE* PosixCertificateVerifier::EnsureTrustStore() {
  std::lock_guard lock(store_mutex_);
  if (store_initialized_) return store_;
  store_initialized_ = true;

  ErrCleaner cleaner;
  ScopedStore store(X509_STORE_new());
  if (!store) return nullptr;

  if (exclusive_roots_.has_value()) {
    for (const auto& root_der : *exclusive_roots_) {
      ScopedX509 cert = ParseDER(root_der.data(), root_der.size());
      if (!cert || X509_STORE_add_cert(store.get(), cert.get()) != 1) {
        return nullptr;
      }
    }
    store_ = store.release();
    return store_;
  }

  if (!LoadSystemRootsLinux(store.get())) return nullptr;
  store_ = store.release();
  return store_;
}
#endif

bool PosixCertificateVerifier::VerifyChain(const webrtc::SSLCertChain& chain) {
  uint32_t error = kErrorInvalidData;
  try {
#if defined(__APPLE__)
    error = VerifyServerChainMacOS(chain, exclusive_roots_, verify_unix_seconds_);
#else
    error = VerifyServerChainLinux(chain, EnsureTrustStore(), verify_unix_seconds_);
#endif
  } catch (const std::bad_alloc&) {
    error = kErrorOutOfMemory;
  } catch (...) {
    error = kErrorInvalidData;
  }
  return diagnostics_->Record(error);
}

bool PosixCertificateVerifier::Verify(const webrtc::SSLCertificate& certificate) {
  try {
    return VerifyChain(webrtc::SSLCertChain(certificate.Clone()));
  } catch (...) {
    return diagnostics_->Record(kErrorInvalidData);
  }
}

}  // namespace micdrop
