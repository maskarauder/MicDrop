#!/usr/bin/env bash
# SPDX-License-Identifier: MPL-2.0
# Capture deterministic iPhone App Store screenshots from booted iOS Simulators,
# normalize them to strict 24-bit RGB PNGs (no alpha channel), and validate Apple specs.
set -euo pipefail

if [ "$#" -lt 2 ] || [ "$#" -gt 3 ]; then
  echo "Usage: $0 <MicDrop.app> <output_root> [display_classes]" >&2
  exit 2
fi

APP_PATH="$1"
OUT_ROOT="$2"
DISPLAY_CLASSES="${3:-all}"
BUNDLE_ID="${MICDROP_BUNDLE_ID:-com.maskarauder.micdrop}"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
TOOL="$REPO_ROOT/tools/app_store_screenshots.py"

if [ ! -d "$APP_PATH" ]; then
  echo "Missing simulator app bundle: $APP_PATH" >&2
  exit 1
fi

mkdir -p "$OUT_ROOT"

WORK_TMP="$(mktemp -d "${RUNNER_TEMP:-/tmp}/micdrop-ios-screenshots.XXXXXX")"
ACTIVE_UDID=""

cleanup() {
  if [ -n "$ACTIVE_UDID" ]; then
    xcrun simctl terminate "$ACTIVE_UDID" "$BUNDLE_ID" >/dev/null 2>&1 || true
    xcrun simctl status_bar "$ACTIVE_UDID" clear >/dev/null 2>&1 || true
    xcrun simctl shutdown "$ACTIVE_UDID" >/dev/null 2>&1 || true
  fi
  rm -rf "$WORK_TMP"
}
trap cleanup EXIT

SIM_LIST_FILE="$WORK_TMP/simulators.tsv"
xcrun simctl list devices available -j | python3 "$TOOL" select-simulators \
  --display-classes "$DISPLAY_CLASSES" \
  --format tsv > "$SIM_LIST_FILE"

SCENES=(
  "connection:01-connection-setup.png"
  "connected_output:02-connected-audio-output.png"
  "microphone:03-microphone-controls.png"
  "diagnostics:04-diagnostics-local-test.png"
)

while IFS=$'\t' read -r display_class udid sim_name runtime; do
  [ -n "$display_class" ] || continue
  echo "=== Capturing $display_class screenshots on $sim_name (iOS $runtime) [$udid] ==="

  ACTIVE_UDID="$udid"
  xcrun simctl boot "$udid" >/dev/null 2>&1 || true
  xcrun simctl bootstatus "$udid" -b

  xcrun simctl ui "$udid" appearance dark
  xcrun simctl status_bar "$udid" override \
    --time "9:41" \
    --dataNetwork wifi \
    --wifiMode active \
    --wifiBars 3 \
    --cellularMode active \
    --cellularBars 4 \
    --operatorName "" \
    --batteryState charged \
    --batteryLevel 100
  sleep 1

  xcrun simctl uninstall "$udid" "$BUNDLE_ID" >/dev/null 2>&1 || true
  xcrun simctl install "$udid" "$APP_PATH"

  DATA_DIR="$(xcrun simctl get_app_container "$udid" "$BUNDLE_ID" data)"
  mkdir -p "$DATA_DIR/tmp"

  RAW_DIR="$WORK_TMP/raw-$display_class"
  mkdir -p "$RAW_DIR"

  for entry in "${SCENES[@]}"; do
    scene="${entry%%:*}"
    filename="${entry#*:}"
    ready_name="micdrop-screenshot-ready-${scene}.txt"
    ready_path="$DATA_DIR/tmp/$ready_name"

    xcrun simctl terminate "$udid" "$BUNDLE_ID" >/dev/null 2>&1 || true
    rm -f "$ready_path"

    SIMCTL_CHILD_MICDROP_SCREENSHOT_SCENE="$scene" \
    SIMCTL_CHILD_MICDROP_SCREENSHOT_READY="$ready_name" \
      xcrun simctl launch "$udid" "$BUNDLE_ID" \
        --micdrop-screenshot-scene "$scene" \
        --micdrop-screenshot-ready "$ready_name" >/dev/null

    ready=0
    for _ in $(seq 1 150); do
      if [ -f "$ready_path" ]; then
        ready=1
        break
      fi
      sleep 0.2
    done

    if [ "$ready" -ne 1 ]; then
      echo "::error::Timed out waiting for iOS screenshot scene '$scene' on $sim_name ($display_class)." >&2
      xcrun simctl io "$udid" screenshot --type=png --mask=ignored \
        "$OUT_ROOT/debug-timeout-${display_class}-${scene}.png" >/dev/null 2>&1 || true
      xcrun simctl spawn "$udid" log show --last 30s --style compact \
        --predicate 'process == "MicDrop"' >&2 || true
      exit 1
    fi

    sleep 0.5
    xcrun simctl io "$udid" screenshot --type=png --mask=ignored "$RAW_DIR/$filename"
    xcrun simctl terminate "$udid" "$BUNDLE_ID" >/dev/null 2>&1 || true
    rm -f "$ready_path"
  done

  xcrun simctl status_bar "$udid" clear >/dev/null 2>&1 || true
  xcrun simctl shutdown "$udid" >/dev/null 2>&1 || true
  ACTIVE_UDID=""

  rm -rf "$OUT_ROOT/$display_class"
  python3 "$TOOL" normalize "$RAW_DIR" "$OUT_ROOT/$display_class" --display-class "$display_class"
done < "$SIM_LIST_FILE"
