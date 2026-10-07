#!/bin/bash
set -euo pipefail
source "$HOME/.zprofile"
configuration=/private/tmp/offline-xcode-config.json
version=$(jq -er .configuration.version "$configuration")
build=$(jq -er .configuration.build "$configuration")
application="/Applications/Xcode_$version.app"
[[ $(sw_vers -productVersion) == "$EXPECTED_VERSION" && $(sw_vers -buildVersion) == "$EXPECTED_BUILD" ]] || exit 1
[[ $(xcode-select -p) == "$application/Contents/Developer" ]] || exit 1
[[ $(xcodebuild -version) == "$(printf 'Xcode %s\nBuild version %s' "$version" "$build")" ]] || exit 1
xcodebuild -checkFirstLaunchStatus
signature_options=(--verify --deep --strict)
if jq -e '.configuration.profile.trimIntel == true or (.configuration.platforms | length) < 4' "$configuration" >/dev/null; then
  signature_options+=(--ignore-resources)
fi
codesign "${signature_options[@]}" "$application"
xcodebuild -showsdks
[[ $(xcrun --find swift) == "$application/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/bin/swift" ]] || exit 1
xcrun swift --version
xcrun --find metal
xcrun metal --version
for platform in iOS watchOS tvOS xrOS; do
  root="/Library/Developer/DeveloperDiskImages/${platform}_DDI"
  [[ $(plutil -extract ProductBuildVersion raw "$root/version.plist") == "$build" ]] || exit 1
  [[ $(plutil -extract Platform raw "$root/version.plist") == "$platform" ]] || exit 1
  test -f "$root/Restore/BuildManifest.plist"
  test -f "$root/Restore/Restore.plist"
done
hub="$application/Contents/Applications/DeviceHub.app"
codesign "${signature_options[@]}" "$hub"
[[ $(plutil -extract CFBundleIdentifier raw "$hub/Contents/Info.plist") == com.apple.dt.Devices ]] || exit 1
[[ $(plutil -extract CFBundleShortVersionString raw "$hub/Contents/Info.plist") == "$version" ]] || exit 1
printf 'XCODE_TOOLS=passed\n'
