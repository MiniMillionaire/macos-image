#!/bin/bash
set -euo pipefail
source "$HOME/.zprofile"
configuration=/private/tmp/offline-xcode-config.json
xcode_version=$(jq -er .configuration.version "$configuration")
platform=${MISO_SIMULATOR_PLATFORM:?}
case "$platform" in
  ios) runtime=iOS; platform_name=iOS; device=iPhone ;;
  watchos) runtime=watchOS; platform_name=watchOS; device=Apple-Watch ;;
  tvos) runtime=tvOS; platform_name=tvOS; device=Apple-TV ;;
  visionos) runtime=xrOS; platform_name=visionOS; device=Apple-Vision ;;
  *) exit 64 ;;
esac
version=$(jq -er --arg platform "$platform_name" '.runtimes[]|select(.platform == $platform)|.version' "$configuration")
build=$(jq -er --arg platform "$platform_name" '.runtimes[]|select(.platform == $platform)|.build' "$configuration")
encoded=$(jq -nr --arg version "$version" '$version|split(".")|map(tonumber)|.[0]*65536+.[1]*256+(.[2]//0)')
identifier="com.apple.CoreSimulator.SimRuntime.$runtime-${version//./-}"
report=$(xcrun simctl list runtimes --json)
printf '%s\n' "$report" | jq -e --arg identifier "$identifier" --arg build "$build" --arg version "$version" '[.runtimes[]|select(.identifier == $identifier and .version == $version and .buildversion == $build and .isAvailable == true)]|length == 1'
type=$(xcrun simctl list devicetypes --json | jq -er --argjson encoded "$encoded" --arg prefix "com.apple.CoreSimulator.SimDeviceType.$device" '[.devicetypes[]|select((.identifier|startswith($prefix)) and (.minRuntimeVersion // 0) <= $encoded and (.maxRuntimeVersion // 4294967295) >= $encoded)]|sort_by(.minRuntimeVersion // 0)|last.identifier|select(type == "string")')
printf "SIM_EVENT=create PLATFORM=%s TIME=%s\n" "$platform" "$(date -u +%FT%TZ)"
name="MISO-$platform-$(uuidgen)"
udid=$(xcrun simctl create "$name" "$type" "$identifier")
[[ "$udid" =~ ^[0-9A-F-]{36}$ ]]
finish() {
  result=$?
  trap - EXIT
  printf "SIM_EVENT=shutdown UDID=%s TIME=%s\n" "$udid" "$(date -u +%FT%TZ)"
  xcrun simctl shutdown "$udid" || result=1
  printf "SIM_EVENT=delete UDID=%s TIME=%s\n" "$udid" "$(date -u +%FT%TZ)"
  xcrun simctl delete "$udid" || result=1
  if [[ -n "${work:-}" ]]; then rm -rf "$work"; fi
  exit "$result"
}
trap finish EXIT
open "/Applications/Xcode_$xcode_version.app/Contents/Applications/DeviceHub.app"
xcrun simctl boot "$udid"
/usr/bin/perl -e 'alarm 300; exec @ARGV' xcrun simctl bootstatus "$udid" -b
xcrun simctl list devices --json | jq -e --arg runtime "$identifier" --arg udid "$udid" '[.devices[$runtime][]|select(.udid == $udid and .state == "Booted" and .isAvailable == true)]|length == 1'
printf 'SIMULATOR=%s BUILD=%s DEVICE=%s UDID=%s BOOT=passed\n' "$identifier" "$build" "$type" "$udid"
work=$(mktemp -d /private/tmp/miso-simulator-probe.XXXXXXXX)
case "$work" in /private/tmp/miso-simulator-probe.*) ;; *) exit 64 ;; esac
case "$platform" in
 ios) sdk=iphonesimulator; target=arm64-apple-ios${version}-simulator ;;
 watchos) sdk=watchsimulator; target=arm64-apple-watchos${version}-simulator ;;
 tvos) sdk=appletvsimulator; target=arm64-apple-tvos${version}-simulator ;;
 visionos) sdk=xrsimulator; target=arm64-apple-xros${version}-simulator ;;
esac
cat > "$work/probe.m" <<'OBJC'
#import <Foundation/Foundation.h>
int main(void) {
    @autoreleasepool {
        NSArray<NSNumber *> *values = @[@6, @7];
        int answer = values[0].intValue * values[1].intValue;
        if (answer != 42 || ![NSJSONSerialization isValidJSONObject:values]) return 1;
        NSData *encoded = [NSJSONSerialization dataWithJSONObject:values options:0 error:NULL];
        if (!encoded || ![[NSJSONSerialization JSONObjectWithData:encoded options:0 error:NULL] isEqual:values]) return 2;
        puts("SIM_EXEC_PASSED=42 FOUNDATION_JSON=passed");
    }
    return 0;
}
OBJC
xcrun --sdk "$sdk" clang --target="$target" -isysroot "$(xcrun --sdk "$sdk" --show-sdk-path)" -Wall -Werror -fobjc-arc -framework Foundation "$work/probe.m" -o "$work/probe"
codesign --force --sign - "$work/probe"
xcrun simctl spawn "$udid" "$work/probe"
sleep 20
printf 'SIM_CONTEXT_BEGIN=%s UDID=%s TIME=%s\n' "$platform" "$udid" "$(date -u +%FT%TZ)"
xcrun simctl spawn "$udid" log show --last 5m --style json --info --debug --predicate '(process == "corespotlightd" OR process == "itunescloudd" OR process == "backboardd" OR process == "AppIntentsLiveEntityService" OR process == "UsageTrackingAgent") AND (messageType == error OR messageType == fault OR eventMessage CONTAINS[c] "exception" OR eventMessage CONTAINS[c] "Terminating" OR eventMessage CONTAINS[c] "audio settings")'
printf 'SIM_CONTEXT_END=%s\n' "$platform"
