// SPDX-License-Identifier: MPL-2.0
#include "posix_certificate_verifier.h"

#include <new>
#include <sys/stat.h>

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

ScopedX509 ParseDER(const uint8_t* data, size_t size) {
  if (!data || size == 0 || size > 1024 * 1024) return nullptr;
  const uint8_t* ptr = data;
  return ScopedX509(d2i_X509(nullptr, &ptr, static_cast<long>(size)));
}

#if defined(__APPLE__)
bool LoadSystemRootsMacOS(X509_STORE* store) {
  CFArrayRef anchors = nullptr;
  if (SecTrustCopyAnchorCertificates(&anchors) != errSecSuccess || !anchors) {
    return false;
  }
  struct ArrayGuard {
    CFArrayRef ref;
    ~ArrayGuard() {
      if (ref) CFRelease(ref);
    }
  } guard{anchors};

  const CFIndex count = CFArrayGetCount(anchors);
  size_t loaded = 0;
  for (CFIndex i = 0; i < count; ++i) {
    const void* item = CFArrayGetValueAtIndex(anchors, i);
    if (!item) continue;
    auto cert_ref = reinterpret_cast<SecCertificateRef>(const_cast<void*>(item));
    CFDataRef der_data = SecCertificateCopyData(cert_ref);
    if (!der_data) continue;
    const UInt8* bytes = CFDataGetBytePtr(der_data);
    const CFIndex length = CFDataGetLength(der_data);
    ScopedX509 parsed = (bytes && length > 0)
                            ? ParseDER(bytes, static_cast<size_t>(length))
                            : nullptr;
    CFRelease(der_data);
    if (parsed && X509_STORE_add_cert(store, parsed.get()) == 1) {
      ++loaded;
    }
    ERR_clear_error();
  }
  return loaded > 0;
}
#else
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
#endif

uint32_t VerifyServerChain(const webrtc::SSLCertChain& certificates, X509_STORE* store) {
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

  if (X509_verify_cert(ctx.get()) == 1) {
    return 0;
  }
  const int verify_error = X509_STORE_CTX_get_error(ctx.get());
  return verify_error > 0 ? static_cast<uint32_t>(verify_error) : kErrorInvalidData;
}

}  // namespace

PosixCertificateVerifier::PosixCertificateVerifier(
    std::shared_ptr<TLSVerificationDiagnostics> diagnostics,
    std::optional<RootList> exclusive_roots)
    : diagnostics_(std::move(diagnostics)), exclusive_roots_(std::move(exclusive_roots)) {}

PosixCertificateVerifier::~PosixCertificateVerifier() {
  if (store_) {
    X509_STORE_free(store_);
    store_ = nullptr;
  }
}

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

#if defined(__APPLE__)
  if (!LoadSystemRootsMacOS(store.get())) return nullptr;
#else
  if (!LoadSystemRootsLinux(store.get())) return nullptr;
#endif
  store_ = store.release();
  return store_;
}

bool PosixCertificateVerifier::VerifyChain(const webrtc::SSLCertChain& chain) {
  uint32_t error = kErrorInvalidData;
  try {
    error = VerifyServerChain(chain, EnsureTrustStore());
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
