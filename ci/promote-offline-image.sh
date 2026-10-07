#!/usr/bin/env bash
set -euo pipefail

[[ ${IMAGE_PROFILE:-} =~ ^[A-Za-z0-9][A-Za-z0-9._-]*$ && "$IMAGE_PROFILE" != *..* ]] || exit 1
[[ ${VARIANT:-} == vanilla || ${VARIANT:-} == base || ${VARIANT:-} == xcode ]] || exit 1
[[ ${XCODE_FLAVOR:-full} == full || ${XCODE_FLAVOR:-full} == slim ]] || exit 1
root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
config="$root/config/miso/$IMAGE_PROFILE"
[[ -d "$config" && ! -L "$config" ]] || exit 1
profile="$config/profile.json"
record="$config/acceptance-$VARIANT.json"
package_variant=$VARIANT
tag=$(jq -er .target.version "$profile")
if [[ "$VARIANT" == xcode ]]; then
  [[ ${XCODE_VERSION:-} =~ ^[A-Za-z0-9][A-Za-z0-9._-]*$ && "$XCODE_VERSION" != *..* ]] || exit 1
  record="$config/acceptance-xcode-$XCODE_VERSION.json"
  configuration=$(cat "$config/xcode-$XCODE_VERSION.json")
  if [[ ${XCODE_FLAVOR:-full} == slim ]]; then
    package_variant=slim-xcode
    record="$config/acceptance-slim-xcode-$XCODE_VERSION.json"
    configuration=$(jq '.platforms = ["iOS","watchOS"] |
      .profile = {platforms:.platforms,trimIntel:true,transparentCompression:true,cleanup:true,sparsify:true}' \
      <<< "$configuration")
  fi
  jq -e --argjson configuration "$configuration" --arg flavor "${XCODE_FLAVOR:-full}" \
    '.xcodeConfiguration == $configuration and (.xcodeFlavor // "full") == $flavor' "$record" >/dev/null
  xcode_tag=$XCODE_VERSION
  if [[ "$xcode_tag" =~ ^([0-9]+(\.[0-9]+)*)(beta|rc)([0-9]*)$ ]]; then
    xcode_tag="${BASH_REMATCH[1]}-${BASH_REMATCH[3]}${BASH_REMATCH[4]}"
  fi
  tag="$tag-xcode$xcode_tag"
fi
[[ "$tag" =~ ^[A-Za-z0-9][A-Za-z0-9._-]*$ ]] || exit 1
jq -e --argjson target "$(jq .target "$profile")" --arg variant "$VARIANT" '
  .target == $target and .variant == $variant and .anonymousDownloadVerified == true and
  .constructionVMStarted == false and
  (.runtime.exitCode == 0 or
    (.runtime.exitCode == 1 and .runtime.review.accepted == true and
     .runtime.review.approvedBy == "cocoa-xu" and
     .runtime.review.failedChecks == ["notification-center"] and
     .runtime.review.supplementalExitCode == 0)) and .runtime.vmStopped == true and
  .runtime.sourceUnchanged == true and .runtime.rosettaInstalled == false and
  .runtime.manualGuestRepair == false
' "$record" >/dev/null
reference=$(jq -er .reference "$record")
repository="$(jq -er .repository "$profile")-$package_variant"
digest=${reference##*@}
[[ "$digest" =~ ^sha256:[0-9a-f]{64}$ && "$reference" == "$repository@$digest" ]] || exit 1
scratch=$(mktemp -d)
trap 'rm -rf "$scratch"' EXIT
printf '{}\n' > "$scratch/anonymous.json"
printf '{}\n' > "$scratch/registry.json"
[[ $(oras resolve "$reference" --registry-config "$scratch/anonymous.json") == "$digest" ]] || exit 1
published="$repository:$tag"
if existing=$(oras resolve "$published" --registry-config "$scratch/anonymous.json" 2> "$scratch/existing.log"); then
  [[ "$existing" == "$digest" ]] || { printf 'Refusing to replace existing tag: %s\n' "$published" >&2; exit 1; }
else
  printf '%s' "$GH_TOKEN" | oras login ghcr.io --username "$GITHUB_ACTOR" \
    --password-stdin --registry-config "$scratch/registry.json"
  oras tag "$reference" "$tag" --registry-config "$scratch/registry.json"
fi
[[ $(oras resolve "$published" --registry-config "$scratch/anonymous.json") == "$digest" ]] || exit 1
build_run=$(jq -er '.buildRun | split("/") | last' "$record")
[[ "$build_run" =~ ^[0-9]+$ ]] || exit 1
candidate_prefix="miso-$(jq -er .target.version "$profile")"
if [[ "$VARIANT" == xcode ]]; then candidate_prefix="$candidate_prefix-xcode-$XCODE_VERSION"; fi
bash "$root/ci/cleanup-offline-candidates.sh" "$repository" "$tag" "$digest" "$candidate_prefix-$build_run-"
printf 'Published %s at %s.\n\n' "$published" "$digest" >> "$GITHUB_STEP_SUMMARY"
