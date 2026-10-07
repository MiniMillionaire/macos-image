#!/bin/bash
set -euo pipefail
root=$(cd "$(dirname "$0")/../.." && pwd -P)
work=${ACCEPTANCE_WORKSPACE:?}
[[ "$work" == "$RUNNER_TEMP/"* && ! -e "$work" ]] || exit 1
[[ "$BUILD_RUN" =~ ^[0-9]+$ ]] || exit 1
[[ "$MACOS_VERSION" =~ ^[0-9]+[.][0-9]+([.][0-9]+)?$ ]] || exit 1
[[ "$IMAGE_TYPE" == vanilla || "$IMAGE_TYPE" == base || "$IMAGE_TYPE" == xcode ]] || exit 1
[[ "$XCODE_FLAVOR" == full || "$XCODE_FLAVOR" == slim ]] || exit 1
mkdir -p "$work/cloud" "$work/tools" "$work/tart/vms" "$work/evidence"
gh run view "$BUILD_RUN" --repo "$GITHUB_REPOSITORY" \
  --json status,conclusion,headBranch,headSha,workflowName,url > "$work/evidence/build-run.json"
jq -e '.status == "completed" and (.conclusion == "success" or .conclusion == "failure") and
  .headBranch == "main" and .workflowName == "Build offline macOS images"' \
  "$work/evidence/build-run.json" >/dev/null
attempt=$(gh api "repos/$GITHUB_REPOSITORY/actions/runs/$BUILD_RUN" --jq .run_attempt)
[[ "$attempt" =~ ^[0-9]+$ ]] || exit 1
pattern="offline-$MACOS_VERSION-$IMAGE_TYPE-$BUILD_RUN-$attempt"
if [[ "$IMAGE_TYPE" == xcode ]]; then
  [[ "$XCODE_VERSION" =~ ^[A-Za-z0-9][A-Za-z0-9._-]*$ && "$XCODE_VERSION" != *..* ]] || exit 1
  pattern="offline-$MACOS_VERSION-xcode-$XCODE_VERSION-$XCODE_FLAVOR-$BUILD_RUN-$attempt"
fi
gh run download "$BUILD_RUN" --repo "$GITHUB_REPOSITORY" --name "$pattern" --dir "$work/cloud"
for step in export publish; do
  [[ $(cat "$work/cloud/$step.status") == exit=0 ]] || {
    printf 'Candidate %s did not finish successfully.\n' "$step" >&2
    exit 1
  }
done
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
reference=$(jq -er .reference "$publication")
cache="$HOME/.cache/macos-image/acceptance/${reference##*@sha256:}"
[[ ! -L "$cache" ]] || exit 1
if [[ -d "$cache" ]]; then
  [[ $(cat "$cache/reference.txt") == "$reference" ]] || exit 1
  stat -f '%i %z %b %m %c' "$cache/vm/"{disk.img,nvram.bin,config.json} > "$work/evidence/cache-state.txt"
  cmp "$cache/state.txt" "$work/evidence/cache-state.txt"
  printf 'Reusing the unchanged candidate downloaded for the previous VM attempt.\n'
else
  printf 'Downloading candidate for VM acceptance.\n'
  miso bundle pull "$reference" --output "$work/download" \
    --concurrency 8 > "$work/evidence/download.json"
  mkdir -p "$cache"
  mv "$work/download/vm" "$cache/vm"
  cp "$work/evidence/download.json" "$cache/download.json"
  printf '%s\n' "$reference" > "$cache/reference.txt"
  stat -f '%i %z %b %m %c' "$cache/vm/"{disk.img,nvram.bin,config.json} > "$cache/state.txt"
fi
cp "$cache/download.json" "$work/evidence/download.json"
printf '%s\n' "$cache" > "$work/evidence/source-cache.txt"
mkdir "$work/tart/vms/source"
for file in disk.img nvram.bin config.json; do
  [[ -f "$cache/vm/$file" && ! -L "$cache/vm/$file" ]] || exit 1
  cp -c "$cache/vm/$file" "$work/tart/vms/source/$file"
done
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
