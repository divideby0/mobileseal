#!/bin/sh
# CED-11 green-gate runner (gates 1-3 + the simulator halves of 4/5).
# Prerequisite (one-time, admin): sudo xcodebuild -runFirstLaunch
# and, if no iOS simulator runtime is installed yet:
#   xcodebuild -downloadPlatform iOS
#
# Usage: Scripts/run-gates.sh [simulator-name]
set -eu
cd "$(dirname "$0")/.."

SIM_NAME="${1:-iPhone 17}"
DEST="platform=iOS Simulator,name=${SIM_NAME}"

echo "== Gate 1c: VaultCore macOS suite =="
swift test

echo "== Gate 1b: generic unsigned device build =="
xcodebuild -project MobileSeal.xcodeproj -scheme MobileSeal \
  -destination 'generic/platform=iOS' \
  CODE_SIGNING_ALLOWED=NO build

echo "== Gate 1a + unit halves of gates 2/4/5: simulator build & unit tests =="
xcodebuild -project MobileSeal.xcodeproj -scheme MobileSeal \
  -destination "$DEST" \
  -only-testing:MobileSealTests \
  test

echo "== Gate 2: scripted e2e (UI) =="
xcodebuild -project MobileSeal.xcodeproj -scheme MobileSeal \
  -destination "$DEST" \
  -only-testing:MobileSealUITests/E2EFlowUITests \
  test

echo "== Gate 3: instrumented 500-photo scroll perf (UI) =="
xcodebuild -project MobileSeal.xcodeproj -scheme MobileSeal \
  -destination "$DEST" \
  -only-testing:MobileSealUITests/GridScrollPerfUITests \
  test

echo "All simulator gates passed."
