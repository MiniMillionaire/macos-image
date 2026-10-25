#!/bin/bash
set -euo pipefail
export PATH=/opt/homebrew/bin:/usr/bin:/bin:/usr/sbin:/sbin
work=/private/tmp/macos-image-components
configuration="$work/xcode.json"
requirements="$work/requirements.json"
version=$(jq -er .version "$configuration")
build=$(jq -er .build "$configuration")
[[ "$version" =~ ^[0-9]+([.][0-9]+)*$ && "$build" =~ ^[0-9]+[A-Z][0-9]+[a-z]?$ ]]
application="/Applications/Xcode_$version.app"
sudo -n xcode-select --switch "$application/Contents/Developer"
[[ $(xcodebuild -version) == "$(printf 'Xcode %s\nBuild version %s' "$version" "$build")" ]]
sudo -n xcodebuild -license accept
sudo -n xcodebuild -runFirstLaunch
xcrun simctl list runtimes -j > "$work/runtimes-before.json"
xcrun simctl runtime list -j > "$work/before.json"
jq --slurpfile requirements "$requirements" -f "$work/runtime-removals.jq" \
  "$work/before.json" > "$work/remove.json"
while IFS= read -r identifier; do
  [[ "$identifier" =~ ^[0-9A-Fa-f-]{36}$ ]]
  xcrun simctl runtime delete "$identifier"
done < <(jq -r '.[].identifier' "$work/remove.json")
removed=false
for attempt in {1..60}; do
  xcrun simctl list runtimes -j > "$work/removing-runtimes.json"
  xcrun simctl runtime list -j > "$work/removing-images.json"
  if jq -e --slurpfile remove "$work/remove.json" --slurpfile images "$work/removing-images.json" '
    .runtimes as $runtimes |
    all($remove[0][]; . as $old |
      all($images[0][]; .identifier != $old.identifier) and
      all($runtimes[]; .identifier != $old.runtimeIdentifier or .isAvailable != true))
  ' "$work/removing-runtimes.json" >/dev/null; then
    removed=true
    break
  fi
  sleep 5
done
[[ "$removed" == true ]] || { printf 'Simulator removal did not complete.\n' >&2; exit 1; }

download() {
  local attempt
  for attempt in 1 2 3; do
    if xcodebuild "$@"; then return; fi
    (( attempt < 3 )) || return 1
    sleep "$((attempt * 30))"
  done
}
while IFS=$'\t' read -r platform runtime_build identifier; do
  if jq -e --slurpfile remove "$work/remove.json" --arg identifier "$identifier" --arg build "$runtime_build" '
    [.[] | select(.runtimeIdentifier == $identifier and .build == $build) |
      .identifier as $id | select(all($remove[0][]; .identifier != $id))] | length == 1
  ' "$work/before.json" >/dev/null; then
    printf 'Runtime already installed: %s %s\n' "$platform" "$runtime_build"
    continue
  fi
  download -downloadPlatform "$platform" -buildVersion "$runtime_build" -architectureVariant arm64
done < <(jq -r '.runtimes[] | [.platform,.build,
  ("com.apple.CoreSimulator.SimRuntime." + (if .platform == "visionOS" then "xrOS" else .platform end) +
   "-" + (.version | gsub("\\."; "-")))] | @tsv' "$requirements")
while IFS= read -r component; do
  if xcodebuild -showComponent "$component" -json > "$work/component.json" &&
    jq -e '.status == "installed"' "$work/component.json" >/dev/null; then
    printf 'Component already installed: %s\n' "$component"
  else
    download -downloadComponent "$component"
  fi
done < <(jq -r '.components[]' "$configuration")
xcrun simctl runtime dyld_shared_cache update --all
ready=false
for attempt in {1..60}; do
  xcrun simctl list runtimes -j > "$work/runtimes.json"
  xcrun simctl runtime list -j > "$work/after.json"
  if jq -e --slurpfile requirements "$requirements" --slurpfile images "$work/after.json" \
    -f "$work/runtime-inventory.jq" "$work/runtimes.json" > "$work/inventory.json" 2> "$work/inventory.stderr" &&
    jq -e 'all(.[]; .kind != "Legacy Download")' "$work/inventory.json" >/dev/null; then
    ready=true
    break
  fi
  sleep 5
done
[[ "$ready" == true ]] || { cat "$work/inventory.stderr" >&2; exit 1; }
if jq -e '.components | index("MetalToolchain") != null' "$configuration" >/dev/null; then
  xcodebuild -showComponent MetalToolchain -json > "$work/metal.json"
  jq -e '.status == "installed"' "$work/metal.json" >/dev/null
  xcrun metal --version
fi
xcodebuild -checkFirstLaunchStatus
jq -n --slurpfile configuration "$configuration" --slurpfile images "$work/after.json" \
  '{method:"xcodebuild",configuration:$configuration[0],runtimes:[$images[0][] |
    {identifier,runtimeIdentifier,build,version,kind,state}],completed:true}' > "$work/receipt.json"
