#!/bin/bash
set -euo pipefail
source "$HOME/.zprofile"
configuration=/private/tmp/offline-xcode-config.json
xcode_version=$(jq -er .configuration.version "$configuration")
work=$(mktemp -d /private/tmp/miso-xcode-acceptance.XXXXXXXX)
case "$work" in /private/tmp/miso-xcode-acceptance.*) ;; *) exit 64 ;; esac
trap 'rm -rf "$work"' EXIT
cat > "$work/probe.c" <<'C'
#include <TargetConditionals.h>
#include <stdlib.h>
int miso_answer(int left, int right) { return left * right; }
C
sdks=(macosx iphoneos iphonesimulator watchos watchsimulator appletvos appletvsimulator xros xrsimulator)
targets=(arm64-apple-macos arm64-apple-ios arm64-apple-ios arm64_32-apple-watchos arm64-apple-watchos arm64-apple-tvos arm64-apple-tvos arm64-apple-xros arm64-apple-xros)
compiled=0
for index in "${!sdks[@]}"; do
  sdk=${sdks[$index]}
  if ! jq -e --arg sdk "$sdk" '.sdks | any(.name == $sdk)' "$configuration" >/dev/null; then
    if xcrun --sdk "$sdk" --show-sdk-path 2>/dev/null; then
      printf 'Excluded SDK is still present: %s\n' "$sdk" >&2
      exit 1
    fi
    continue
  fi
  root=$(xcrun --sdk "$sdk" --show-sdk-path)
  version=$(xcrun --sdk "$sdk" --show-sdk-version)
  test "$version" = "$(jq -er --arg sdk "$sdk" ' .sdks[] | select(.name == $sdk) | .version ' "$configuration")"
  case "$root" in "/Applications/Xcode_$xcode_version.app/Contents/Developer/Platforms/"*) ;; *) exit 1 ;; esac
  printf 'SDK=%s VERSION=%s ROOT=%s\n' "$sdk" "$version" "$root"
  target="${targets[$index]}$version"
  case "$sdk" in *simulator) target="$target-simulator" ;; esac
  xcrun --sdk "$sdk" clang --target="$target" -isysroot "$root" -Wall -Werror -c "$work/probe.c" -o "$work/$sdk.o"
  test -s "$work/$sdk.o"
  otool -hv "$work/$sdk.o"
  compiled=$((compiled + 1))
done
mkdir -p "$work/SwiftSmoke/Sources/MisoSmoke" "$work/SwiftSmoke/Tests/MisoSmokeTests"
cat > "$work/SwiftSmoke/Package.swift" <<'SWIFT'
// swift-tools-version: 6.0
import PackageDescription
let package = Package(name: "MisoSmoke", targets: [.target(name: "MisoSmoke"), .testTarget(name: "MisoSmokeTests", dependencies: ["MisoSmoke"])])
SWIFT
cat > "$work/SwiftSmoke/Sources/MisoSmoke/Answer.swift" <<'SWIFT'
public func multiply(_ left: Int, _ right: Int) -> Int { left * right }
SWIFT
cat > "$work/SwiftSmoke/Tests/MisoSmokeTests/AnswerTests.swift" <<'SWIFT'
import XCTest
@testable import MisoSmoke
final class AnswerTests: XCTestCase {
  func testPositive() { XCTAssertEqual(multiply(6, 7), 42) }
  func testZero() { XCTAssertEqual(multiply(0, 7), 0) }
  func testNegative() { XCTAssertEqual(multiply(-3, 14), -42) }
}
SWIFT
xcrun swift test --package-path "$work/SwiftSmoke" --scratch-path "$work/swift-build" --jobs 2
cat > "$work/probe.metal" <<'METAL'
#include <metal_stdlib>
using namespace metal;
kernel void doubleValue(device float *values [[buffer(0)]], uint index [[thread_position_in_grid]]) { values[index] *= 2.0f; }
METAL
xcrun --sdk macosx metal -c "$work/probe.metal" -o "$work/probe.air"
xcrun --sdk macosx metallib "$work/probe.air" -o "$work/probe.metallib"
test -s "$work/probe.metallib"
printf 'SDK_COMPILES=%s SWIFT_TESTS=3 METAL_LINK=passed\n' "$compiled"
cat > "$work/audio.c" <<'C'
#include <CoreAudio/CoreAudio.h>
#include <stdio.h>
int main(void) {
    AudioObjectPropertyAddress property = { kAudioHardwarePropertyDefaultOutputDevice, kAudioObjectPropertyScopeGlobal, kAudioObjectPropertyElementMain };
    AudioDeviceID device = kAudioObjectUnknown;
    UInt32 size = sizeof(device);
    if (AudioObjectGetPropertyData(kAudioObjectSystemObject, &property, 0, NULL, &size, &device) != noErr || device == kAudioObjectUnknown) return 1;
    property.mSelector = kAudioDevicePropertyNominalSampleRate;
    Float64 rate = 0;
    size = sizeof(rate);
    if (AudioObjectGetPropertyData(device, &property, 0, NULL, &size, &rate) != noErr || rate <= 0) return 2;
    printf("GUEST_AUDIO_DEVICE=%u RATE=%.1f\n", device, rate);
    return 0;
}
C
xcrun clang -Wall -Werror -framework CoreAudio "$work/audio.c" -o "$work/audio"
"$work/audio"
