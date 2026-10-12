#!/bin/bash
set -euo pipefail
source "$HOME/.zprofile"
result=$(mktemp)
trap 'rm -f "$result"' EXIT
xcrun devicectl list preferredDDI --quiet --timeout 60 --json-output "$result"
for platform in iOS watchOS tvOS xrOS; do
  root="/Library/Developer/DeveloperDiskImages/${platform}_DDI"
  build=$(plutil -extract ProductBuildVersion raw "$root/version.plist")
  [[ -n "$build" && $(plutil -extract Platform raw "$root/version.plist") == "$platform" ]] || exit 1
  test -f "$root/Restore/BuildManifest.plist"
  test -f "$root/Restore/Restore.plist"
  jq -e --arg platform "$platform" --arg build "$build" --arg path "file://$root/" '
    .info.outcome == "success" and
    any(.result.platforms[$platform][]?;
      .hostDDI == $path and .ddiMetadata.platform == $platform and
      .ddiMetadata.buildUpdate == $build and .ddiMetadata.isUsable == true)
  ' "$result" >/dev/null
  printf 'DEVELOPER_DISK=%s BUILD=%s USABLE=true\n' "$platform" "$build"
done
printf 'XCODE_DDI=passed\n'
