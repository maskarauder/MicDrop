#!/usr/bin/env bash
# SPDX-License-Identifier: MPL-2.0
# Resilient Ubuntu APT helper for GitHub Actions runners.
# Preserves multiple healthy mirrors in /etc/apt/apt-mirrors.txt for automatic
# failover, caches apt-get update per runner job, and retries transient mirror drops.

set -euo pipefail

MIRRORS_FILE="${MICDROP_APT_MIRRORS_FILE:-/etc/apt/apt-mirrors.txt}"
OS_RELEASE_FILE="${MICDROP_OS_RELEASE_FILE:-/etc/os-release}"
STAMP_FILE="${MICDROP_APT_STAMP_FILE:-${RUNNER_TEMP:-/tmp}/micdrop-apt-updated.stamp}"
RETRY_DELAY="${MICDROP_APT_RETRY_DELAY_SECONDS:-3}"

APT_OPTS=(
  -o Acquire::ForceIPv4=true
  -o Acquire::Retries=3
  -o Acquire::http::Timeout=15
  -o Acquire::https::Timeout=15
  -o Acquire::http::No-Cache=false
  -o Acquire::https::No-Cache=false
  -o DPkg::Lock::Timeout=60
)

detect_codename() {
  local codename=""
  if [ -f "$OS_RELEASE_FILE" ]; then
    codename="$(
      awk -F= '$1 == "VERSION_CODENAME" { gsub(/"/, "", $2); print $2; exit }' "$OS_RELEASE_FILE"
    )"
  fi
  printf '%s\n' "${codename:-noble}"
}

configure_mirrors() {
  local mode="${1:-probe}"
  if [ ! -f "$MIRRORS_FILE" ]; then
    return 0
  fi

  if [ "$mode" = "--fallback" ]; then
    printf '%s\tpriority:1\n%s\tpriority:2\n' \
      "http://archive.ubuntu.com/ubuntu/" \
      "http://azure.archive.ubuntu.com/ubuntu/" | sudo tee "$MIRRORS_FILE" >/dev/null
    return 0
  fi

  local codename
  codename="$(detect_codename)"

  local raw_candidates=(
    "http://azure.archive.ubuntu.com/ubuntu/"
  )
  while IFS= read -r existing; do
    case "$existing" in
      http://* | https://*)
        raw_candidates+=("${existing%/}/")
        ;;
    esac
  done < <(awk 'NF && $1 !~ /^#/ { print $1 }' "$MIRRORS_FILE")

  raw_candidates+=(
    "https://archive.ubuntu.com/ubuntu/"
    "https://mirrors.edge.kernel.org/ubuntu/"
    "https://ftp.osuosl.org/pub/ubuntu/"
  )

  local candidates=()
  local seen=" "
  local mirror
  for mirror in "${raw_candidates[@]}"; do
    mirror="${mirror%/}/"
    case "$seen" in
      *" $mirror "*) ;;
      *)
        seen="${seen}${mirror} "
        candidates+=("$mirror")
        ;;
    esac
  done

  local healthy_lines=""
  local priority=1
  for mirror in "${candidates[@]}"; do
    if curl -4 -fsSLI --connect-timeout 3 --max-time 5 "${mirror}dists/${codename}/InRelease" >/dev/null 2>&1 && \
       curl -4 -fsSLI --connect-timeout 3 --max-time 5 "${mirror}dists/${codename}-security/InRelease" >/dev/null 2>&1; then
      healthy_lines+="$(printf '%s\tpriority:%d\n' "$mirror" "$priority")"$'\n'
      priority=$((priority + 1))
    fi
  done

  if [ "$priority" -gt 1 ]; then
    printf '%s' "$healthy_lines" | sudo tee "$MIRRORS_FILE" >/dev/null
  fi
}

do_update() {
  local force="${1:-}"
  local mirror_mode="${2:-probe}"
  if [ "$force" != "--force" ] && [ -f "$STAMP_FILE" ]; then
    return 0
  fi

  configure_mirrors "$mirror_mode"

  local attempt
  for attempt in 1 2 3; do
    if DEBIAN_FRONTEND=noninteractive sudo apt-get "${APT_OPTS[@]}" update; then
      mkdir -p "$(dirname "$STAMP_FILE")"
      : > "$STAMP_FILE"
      return 0
    fi
    if [ "$attempt" -eq 3 ]; then
      echo "apt-get update failed after ${attempt} attempts" >&2
      return 1
    fi
    echo "apt-get update attempt ${attempt}/3 failed; retrying in ${RETRY_DELAY}s..." >&2
    sleep "$RETRY_DELAY"
    if [ "$attempt" -ge 2 ]; then
      configure_mirrors "--fallback"
    else
      configure_mirrors "probe"
    fi
  done
}

do_install() {
  if [ "$#" -eq 0 ]; then
    echo "Usage: $0 install <package> [package...]" >&2
    return 2
  fi

  do_update

  local attempt
  for attempt in 1 2 3; do
    if DEBIAN_FRONTEND=noninteractive sudo apt-get "${APT_OPTS[@]}" install -y --fix-missing --no-install-recommends "$@"; then
      return 0
    fi
    if [ "$attempt" -eq 3 ]; then
      echo "apt-get install failed after ${attempt} attempts: $*" >&2
      return 1
    fi
    echo "apt-get install attempt ${attempt}/3 failed; refreshing package metadata in ${RETRY_DELAY}s..." >&2
    sleep "$RETRY_DELAY"
    rm -f "$STAMP_FILE"
    if [ "$attempt" -ge 2 ]; then
      do_update --force "--fallback"
    else
      do_update --force "probe"
    fi
  done
}

cmd="${1:-}"
if [ -z "$cmd" ]; then
  echo "Usage: $0 <update [--force] | install <package...>>" >&2
  exit 2
fi
shift

case "$cmd" in
  update)
    do_update "${1:-}"
    ;;
  install)
    do_install "$@"
    ;;
  *)
    echo "Unknown command: $cmd" >&2
    exit 2
    ;;
esac
