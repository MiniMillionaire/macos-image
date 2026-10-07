#!/bin/bash
set -euo pipefail
root=$(cd "$(dirname "$0")/../.." && pwd -P)
work=${ACCEPTANCE_WORKSPACE:?}
[[ "$work" == "$RUNNER_TEMP/"* && ! -e "$work" ]]
[[ "$BUILD_RUN" =~ ^[0-9]+$ ]]
[[ "$MACOS_VERSION" =~ ^[0-9]+[.][0-9]+([.][0-9]+)?$ ]]
[[ "$IMAGE_TYPE" == vanilla || "$IMAGE_TYPE" == base || "$IMAGE_TYPE" == xcode ]]
[[ "$XCODE_FLAVOR" == full || "$XCODE_FLAVOR" == slim ]]
mkdir -p "$work/cloud" "$work/tools" "$work/tart/vms" "$work/evidence"
gh run view "$BUILD_RUN" --repo "$GITHUB_REPOSITORY" \
  --json conclusion,headBranch,headSha,workflowName,url > "$work/evidence/build-run.json"
jq -e '.conclusion == "success" and .headBranch == "main" and .workflowName == "Build offline macOS images"' \
  "$work/evidence/build-run.json" >/dev/null
attempt=$(gh api "repos/$GITHUB_REPOSITORY/actions/runs/$BUILD_RUN" --jq .run_attempt)
[[ "$attempt" =~ ^[0-9]+$ ]]
pattern="offline-$MACOS_VERSION-$IMAGE_TYPE-$BUILD_RUN-$attempt"
if [[ "$IMAGE_TYPE" == xcode ]]; then
  [[ "$XCODE_VERSION" =~ ^[A-Za-z0-9][A-Za-z0-9._-]*$ && "$XCODE_VERSION" != *..* ]]
  pattern="offline-$MACOS_VERSION-xcode-$XCODE_VERSION-$XCODE_FLAVOR-$BUILD_RUN-$attempt"
fi
gh run download "$BUILD_RUN" --repo "$GITHUB_REPOSITORY" --name "$pattern" --dir "$work/cloud"
publication="$work/cloud/publication.json"
package=$IMAGE_TYPE
if [[ "$IMAGE_TYPE" == xcode && "$XCODE_FLAVOR" == slim ]]; then package=slim-xcode; fi
repository="$(jq -er .repository "$root/config/miso/$MACOS_VERSION/profile.json")-$package"
jq -e --arg revision "$(jq -r .headSha "$work/evidence/build-run.json")" \
  --arg repository "$repository" --arg version "$MACOS_VERSION" --arg variant "$IMAGE_TYPE" '
  .revision == $revision and .variant == $variant and .target.version == $version and
  (.uploaded == true or .anonymousDownloadVerified == true) and .vmStarted == false and .runtimeVerified == false and
  (.reference | startswith($repository + "@sha256:")) and
  (.reference | test("@sha256:[0-9a-f]{64}$"))' "$publication" >/dev/null
if [[ "$IMAGE_TYPE" == xcode ]]; then
  jq -e --arg version "$XCODE_VERSION" --arg flavor "$XCODE_FLAVOR" \
    '.xcodeVersion == $version and (.xcodeFlavor // "full") == $flavor' "$publication" >/dev/null
fi
{ sw_vers; sysctl hw.model hw.memsize; miso --version; } > "$work/evidence/host.txt"
unset MISO_REGISTRY_USERNAME MISO_REGISTRY_PASSWORD
printf 'Downloading candidate for VM acceptance.\n'
miso bundle pull "$(jq -er .reference "$publication")" --output "$work/download" \
  --concurrency 8 > "$work/evidence/download.json"
mv "$work/download/vm" "$work/tart/vms/source"
jq -S '{hardwareModel,ecid,cpuCountMin,memorySizeMin,os,arch,diskFormat}' \
  "$work/tart/vms/source/config.json" > "$work/evidence/downloaded-identity.json"
cmp "$work/cloud/source-identity.json" "$work/evidence/downloaded-identity.json"
gh release download "$TART_VERSION" --repo cirruslabs/tart --pattern tart.tar.gz --dir "$work/tools"
tar -xzf "$work/tools/tart.tar.gz" -C "$work/tools"
rm "$work/tools/tart.tar.gz"
codesign --verify --deep --strict "$work/tools/tart.app"
"$work/tools/tart.app/Contents/MacOS/tart" --version >> "$work/evidence/host.txt"
openssl=$(brew --prefix openssl@3)
clang -O2 -Wno-deprecated-declarations -I"$openssl/include" -L"$openssl/lib" \
  "$root/ci/acceptance/helpers/vnc-smoke.c" -lcrypto -o "$work/tools/vnc-smoke"
mkdir -p "$work/tools/InputWitness.app/Contents/MacOS"
swiftc -O "$root/ci/acceptance/helpers/focus-input-witness.swift" -o "$work/tools/InputWitness.app/Contents/MacOS/InputWitness"
cp "$root/ci/acceptance/helpers/InputWitness.plist" "$work/tools/InputWitness.app/Contents/Info.plist"
codesign --force --sign - "$work/tools/InputWitness.app"
df -h /System/Volumes/Data > "$work/evidence/space-prepared.txt"
