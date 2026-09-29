#!/bin/sh
set -eu
cd "$(dirname "$0")/.."
BUILD_DIR=$(mktemp -d /private/tmp/masqfit-core-tests.XXXXXX)
trap 'rm -rf "$BUILD_DIR"' EXIT
DEVELOPER_DIR=${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}
"$DEVELOPER_DIR/Toolchains/XcodeDefault.xctoolchain/usr/bin/swiftc" \
  -sdk "$DEVELOPER_DIR/Platforms/MacOSX.platform/Developer/SDKs/MacOSX.sdk" \
  -target "$(uname -m)-apple-macosx13.0" -module-cache-path "$BUILD_DIR/cache" \
  MasqFit/Anonymous/FacialAggregates.swift MasqFit/Anonymous/MFTCImport.swift MasqFit/Anonymous/AnonymousSubmissionStore.swift \
  Tests/AnonymousCoreTests.swift Tests/AnonymousQueueTests.swift \
  -o "$BUILD_DIR/tests"
"$BUILD_DIR/tests"
