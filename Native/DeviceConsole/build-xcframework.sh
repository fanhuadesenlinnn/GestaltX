#!/bin/bash
# SPDX-License-Identifier: GPL-3.0-only
#
# Build gx_device_console as a static .xcframework for iOS device + simulator
# (arm64 only; x86_64 simulator is intentionally excluded).
#
# Reproducible from source — no prebuilt binaries are committed.
#
# Requirements:
#   - Rust targets:  rustup target add aarch64-apple-ios aarch64-apple-ios-sim
#   - cmake (aws-lc builds from C source); nasm on x86_64 hosts
#   - Xcode command line tools (xcodebuild, lipo)
#
# Output: build/GXDeviceConsole.xcframework  (git-ignored; wired into the Xcode
# project's library + header search paths, not checked in).

set -euo pipefail
cd "$(dirname "$0")"

OUT="build"
LIB="libgx_device_console.a"
HEADERS="include"

check() { command -v "$1" >/dev/null 2>&1 || { echo "error: '$1' not found ($2)"; exit 1; }; }
check cargo "install Rust"
check cmake "brew install cmake — required by aws-lc"
check xcodebuild "install Xcode command line tools"

for t in aarch64-apple-ios aarch64-apple-ios-sim; do
  rustup target list --installed | grep -q "^$t$" || {
    echo "error: missing Rust target $t — run: rustup target add $t"; exit 1; }
done

echo "==> building device (aarch64-apple-ios)"
cargo build --release --no-default-features --features device --target aarch64-apple-ios

echo "==> building simulator (aarch64-apple-ios-sim)"
cargo build --release --no-default-features --features device --target aarch64-apple-ios-sim

rm -rf "$OUT/GXDeviceConsole.xcframework"
mkdir -p "$OUT"

xcodebuild -create-xcframework \
  -library "target/aarch64-apple-ios/release/$LIB" -headers "$HEADERS" \
  -library "target/aarch64-apple-ios-sim/release/$LIB" -headers "$HEADERS" \
  -output "$OUT/GXDeviceConsole.xcframework"

echo "==> done: $OUT/GXDeviceConsole.xcframework"
