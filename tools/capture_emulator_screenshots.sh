#!/usr/bin/env bash
# SPDX-License-Identifier: MPL-2.0
set -euo pipefail

adb wait-for-device
adb shell wm size 1080x1920
adb shell wm density 420
adb shell settings put system accelerometer_rotation 0
adb shell settings put system user_rotation 0
adb shell input keyevent KEYCODE_WAKEUP
adb shell wm dismiss-keyguard
adb shell rm -rf /data/local/tmp/micdrop-screenshots
adb shell mkdir -p /data/local/tmp/micdrop-screenshots

./gradlew --no-daemon \
  -PmicdropEmulatorScreenshots=true \
  :app:connectedDebugAndroidTest \
  -Pandroid.testInstrumentationRunnerArguments.class=com.maskarauder.micdrop.PlayStoreScreenshotsTest \
  -Pandroid.testInstrumentationRunnerArguments.micdropScreenshots=true

RAW_DIR="${RUNNER_TEMP:-/tmp}/raw-screenshots"
OUT_DIR="${RUNNER_TEMP:-/tmp}/play-screenshots"
rm -rf "$RAW_DIR" "$OUT_DIR"
mkdir -p "$RAW_DIR" "$OUT_DIR"
adb pull /data/local/tmp/micdrop-screenshots/. "$RAW_DIR/"
python3 ../../tools/play_store_screenshots.py normalize "$RAW_DIR" "$OUT_DIR"
