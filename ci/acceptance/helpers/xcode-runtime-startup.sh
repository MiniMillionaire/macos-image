#!/bin/bash
set -euo pipefail
source "$HOME/.zprofile"
root=/private/tmp/macos-image-runtime-startup
mkdir "$root"
configuration=/private/tmp/offline-xcode-config.json
validator=/private/tmp/runtime-inventory.jq
started=$(date +%s)
boot=$(/usr/sbin/sysctl -n kern.boottime | awk '{gsub(",", "", $4); print $4}')
bounded() { /usr/bin/perl -e 'alarm shift; exec @ARGV' "$@"; }
event() { printf '%s uptime=%s %s\n' "$(date -u +%FT%TZ)" "$(( $(date +%s) - boot ))" "$*"; }
snapshot() {
  local destination=$1
  bounded 180 xcrun simctl list runtimes -j > "$destination.runtimes.json" || return 1
  bounded 60 xcrun simctl runtime list -j > "$destination.images.json" || return 1
  jq -e --slurpfile requirements "$configuration" --slurpfile images "$destination.images.json" \
    -f "$validator" "$destination.runtimes.json" > "$destination.inventory.json" || return 1
  while IFS= read -r path; do [[ -d "$path" ]] || return 1; done \
    < <(jq -r '.[].bundlePath' "$destination.inventory.json")
}
monitor_pid=
udid=
finish() {
  local status=$?
  trap - EXIT
  if [[ -n "$monitor_pid" ]]; then
    touch "$root/stop"
    wait "$monitor_pid" || status=1
  fi
  if [[ -n "$udid" ]]; then
    bounded 60 xcrun simctl shutdown "$udid" > "$root/shutdown.log" 2>&1 || status=1
    bounded 30 xcrun simctl delete "$udid" > "$root/delete.log" 2>&1 || status=1
  fi
  jq -n --argjson status "$status" --argjson seconds "$(( $(date +%s) - started ))" \
    '{exitCode:$status,observationSeconds:$seconds}' > "$root/result.json"
  exit "$status"
}
trap finish EXIT
event 'initial-runtime-query'
snapshot "$root/initial"
monitor() {
  local sample=0
  while [[ ! -f "$root/stop" ]]; do
    sleep 5
    snapshot "$root/current" || return 1
    cmp "$root/initial.inventory.json" "$root/current.inventory.json" || return 1
    sample=$((sample+1))
    printf '%s\n' "$sample" > "$root/observations.txt"
  done
}
monitor > "$root/monitor.log" 2>&1 &
monitor_pid=$!
runtime=$(jq -er '[.runtimes[] | select(.isAvailable and (.identifier | contains("SimRuntime.iOS")))] | last | .identifier' "$root/initial.runtimes.json")
type=$(jq -er --arg runtime "$runtime" '.runtimes[] | select(.identifier == $runtime) |
  [.supportedDeviceTypes[].identifier | select(contains("iPhone"))] | sort | first' "$root/initial.runtimes.json")
mkdir -p "$root/RuntimeProbe.app"
cat > "$root/probe.m" <<'OBJC'
#import <UIKit/UIKit.h>
@interface ProbeDelegate : UIResponder <UIApplicationDelegate>
@property(nonatomic, strong) UIWindow *window;
@end
@implementation ProbeDelegate
- (BOOL)application:(UIApplication *)application didFinishLaunchingWithOptions:(NSDictionary *)options {
    self.window = [[UIWindow alloc] initWithFrame:UIScreen.mainScreen.bounds];
    self.window.rootViewController = [UIViewController new];
    [self.window makeKeyAndVisible];
    NSLog(@"RUNTIME_PROBE_LAUNCHED");
    return YES;
}
@end
int main(int argc, char **argv) {
    @autoreleasepool { return UIApplicationMain(argc, argv, nil, NSStringFromClass(ProbeDelegate.class)); }
}
OBJC
cat > "$root/RuntimeProbe.app/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleIdentifier</key><string>moe.uwucocoa.runtime-probe</string>
<key>CFBundleExecutable</key><string>RuntimeProbe</string>
<key>CFBundleName</key><string>RuntimeProbe</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>CFBundleVersion</key><string>1</string>
<key>CFBundleShortVersionString</key><string>1.0</string>
<key>MinimumOSVersion</key><string>27.0</string>
<key>CFBundleSupportedPlatforms</key><array><string>iPhoneSimulator</string></array>
<key>UIDeviceFamily</key><array><integer>1</integer><integer>2</integer></array>
<key>LSRequiresIPhoneOS</key><true/>
</dict></plist>
PLIST
version=$(jq -er '.runtimes[] | select(.platform == "iOS") | .version' "$configuration")
/usr/libexec/PlistBuddy -c "Set MinimumOSVersion $version" "$root/RuntimeProbe.app/Info.plist"
event 'compile-application'
bounded 90 xcrun --sdk iphonesimulator clang -target "arm64-apple-ios$version-simulator" \
  -isysroot "$(xcrun --sdk iphonesimulator --show-sdk-path)" -fobjc-arc -framework UIKit \
  "$root/probe.m" -o "$root/RuntimeProbe.app/RuntimeProbe"
codesign --force --sign - "$root/RuntimeProbe.app"
mkdir -p "$root/RuntimeTests/Sources/RuntimeTests" "$root/RuntimeTests/Tests/RuntimeTestsTests"
cat > "$root/RuntimeTests/Package.swift" <<'SWIFT'
// swift-tools-version: 6.0
import PackageDescription
let package = Package(name: "RuntimeTests", platforms: [.iOS(.v15)], products: [
    .library(name: "RuntimeTests", targets: ["RuntimeTests"])
], targets: [.target(name: "RuntimeTests"), .testTarget(name: "RuntimeTestsTests", dependencies: ["RuntimeTests"])])
SWIFT
cat > "$root/RuntimeTests/Sources/RuntimeTests/Runtime.swift" <<'SWIFT'
import Foundation
import UIKit
public func frameworkPath() -> String { Bundle(for: UIApplication.self).bundlePath }
SWIFT
cat > "$root/RuntimeTests/Tests/RuntimeTestsTests/RuntimeTests.swift" <<'SWIFT'
import Foundation
import XCTest
import RuntimeTests
final class RuntimeMountTests: XCTestCase {
    func testSimulatorCanLoadUIKitFromAnExistingRuntime() {
        XCTAssertNotNil(ProcessInfo.processInfo.environment["SIMULATOR_UDID"])
        XCTAssertTrue(FileManager.default.fileExists(atPath: frameworkPath()))
    }
}
SWIFT
exercise() {
  local phase=$1
  event "$phase create"
  udid=$(bounded 30 xcrun simctl create "RuntimeStartup-$phase" "$type" "$runtime")
  [[ "$udid" =~ ^[0-9A-Fa-f-]{36}$ ]]
  bounded 30 xcrun simctl boot "$udid"
  bounded 300 xcrun simctl bootstatus "$udid" -b
  event "$phase install"
  bounded 90 xcrun simctl install "$udid" "$root/RuntimeProbe.app"
  bounded 60 xcrun simctl launch --terminate-running-process "$udid" moe.uwucocoa.runtime-probe
  bounded 30 xcrun simctl get_app_container "$udid" moe.uwucocoa.runtime-probe app
  event "$phase xcodebuild-test"
  (cd "$root/RuntimeTests"; bounded 600 xcodebuild test -scheme RuntimeTests -destination "id=$udid" \
    -parallel-testing-enabled NO -derivedDataPath "$root/DerivedData" -resultBundlePath "$root/$phase.xcresult" \
    -quiet) > "$root/$phase-xcodebuild.log" 2>&1
  event "$phase passed"
  bounded 60 xcrun simctl shutdown "$udid"
  bounded 30 xcrun simctl delete "$udid"
  udid=
}
exercise early
while (( $(date +%s) - started < 690 )); do
  kill -0 "$monitor_pid" || { wait "$monitor_pid"; exit 1; }
  sleep 5
done
exercise delayed
snapshot "$root/final"
cmp "$root/initial.inventory.json" "$root/final.inventory.json"
event 'runtime-startup-stability passed'
