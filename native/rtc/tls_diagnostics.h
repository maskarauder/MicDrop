// SPDX-License-Identifier: MPL-2.0
#pragma once
#include <cstdint>
#include <mutex>

namespace micdrop {

// Counts and a numeric platform/verifier error code only; never certificate names, URLs or DER.
struct TLSVerificationSnapshot {
  uint32_t checks = 0, failures = 0, last_error = 0;
};

class TLSVerificationDiagnostics {
 public:
  bool Record(uint32_t error) {
    std::lock_guard lock(mutex_);
    ++value_.checks;
    if (error) ++value_.failures;
    value_.last_error = error;
    return error == 0;
  }
  TLSVerificationSnapshot Snapshot() const {
    std::lock_guard lock(mutex_);
    return value_;
  }

 private:
  mutable std::mutex mutex_;
  TLSVerificationSnapshot value_;
};

}  // namespace micdrop
