#!/usr/bin/env bash
# Repro: RNFB SPM signature-collision fix misses the -ios-simulator slice.
# Runs from a clean checkout: npm ci -> expo prebuild -> pod install -> 3 xcodebuild cases.
# Each case gets a fresh -derivedDataPath / -archivePath under ./build. Logs: ./build/case*.log
set -uo pipefail
cd "$(dirname "$0")"
export LANG=en_US.UTF-8 LC_ALL=en_US.UTF-8

WORKSPACE=ios/RNFBSigRepro.xcworkspace
SCHEME=RNFBSigRepro
COMMON=(-workspace "$WORKSPACE" -scheme "$SCHEME" -configuration Release
        -destination "generic/platform=iOS Simulator" -xcconfig ci.xcconfig)

step() { printf '\n==> %s\n' "$*"; }

run_case() { # name action expect(pass|fail) [extra xcodebuild args...]
  local name=$1 action=$2 expect=$3; shift 3
  local log=build/$name.log
  step "$name: xcodebuild $action (expect $expect)"
  xcodebuild "$action" "${COMMON[@]}" -derivedDataPath "build/dd-$name" "$@" >"$log" 2>&1
  local rc=$?
  grep -E 'xcodebuild: error|(ARCHIVE|BUILD) (SUCCEEDED|FAILED)' "$log" | tail -3
  local got=pass; [ $rc -ne 0 ] && got=fail
  echo "    exit=$rc result=$got expected=$expect"
  [ "$got" = "$expect" ] || MISMATCH=1
}

MISMATCH=0
rm -rf build ios
mkdir -p build

step "npm ci (lifecycle scripts disabled via .npmrc)"
npm ci || exit 1

step "expo prebuild (iOS only)"
CI=1 npx --no-install expo prebuild --platform ios --no-install || exit 1

step "pod install (stock RNFB)"
(cd ios && pod install) || exit 1

run_case case1-archive archive fail -archivePath build/case1.xcarchive
run_case case2-build   build   pass

step "apply patches/ (adds the -ios-simulator rm lines) and re-run pod install"
npx --no-install patch-package || exit 1
(cd ios && pod install) || exit 1
grep -q 'xcframework-ios-simulator.signature' ios/RNFBSigRepro.xcodeproj/project.pbxproj \
  || { echo "patched phase not found in project.pbxproj"; exit 1; }

run_case case3-archive-patched archive pass -archivePath build/case3.xcarchive

step "restore stock RNFB in node_modules"
npx --no-install patch-package --reverse

if [ $MISMATCH -eq 0 ]; then echo; echo "All cases matched expectations."; else echo; echo "At least one case did NOT match expectations."; exit 1; fi
