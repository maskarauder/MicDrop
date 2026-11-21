#!/usr/bin/env bash
# SPDX-License-Identifier: MPL-2.0
# Installs pinned Android SDK packages on GitHub Actions runners with bounded retries.
# sdkmanager exits non-zero when a package download arrives damaged (for example
# "Error on ZipFile unknown archive"); a later attempt downloads the package again.

set -euo pipefail

SDKMANAGER="${ANDROID_HOME:-}/cmdline-tools/latest/bin/sdkmanager"
RETRY_DELAY="${MICDROP_SDKMANAGER_RETRY_DELAY_SECONDS:-5}"

if [ "$#" -eq 0 ]; then
  echo "Usage: $0 <package> [package...]" >&2
  exit 2
fi
if [ ! -x "$SDKMANAGER" ]; then
  echo "sdkmanager is not available at $SDKMANAGER; check ANDROID_HOME" >&2
  exit 2
fi

for attempt in 1 2 3; do
  if "$SDKMANAGER" "$@"; then
    exit 0
  fi
  if [ "$attempt" -eq 3 ]; then
    echo "sdkmanager failed after ${attempt} attempts: $*" >&2
    exit 1
  fi
  echo "sdkmanager attempt ${attempt}/3 failed; retrying in ${RETRY_DELAY}s..." >&2
  sleep "$RETRY_DELAY"
done
