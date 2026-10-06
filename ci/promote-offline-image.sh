#!/usr/bin/env bash
set -euo pipefail

[[ ${IMAGE_PROFILE:-} =~ ^[A-Za-z0-9][A-Za-z0-9._-]*$ && "$IMAGE_PROFILE" != *..* ]] || exit 1
[[ ${VARIANT:-} == vanilla || ${VARIANT:-} == base || ${VARIANT:-} == xcode ]] || exit 1
root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
config="$root/config/miso/$IMAGE_PROFILE"
[[ -d "$config" && ! -L "$config" ]] || exit 1
profile="$config/profile.json"
record="$config/acceptance-$VARIANT.json"
tag=$(jq -er .target.version "$profile")
if [[ "$VARIANT" == xcode ]]; then
  [[ ${XCODE_VERSION:-} =~ ^[A-Za-z0-9][A-Za-z0-9._-]*$ && "$XCODE_VERSION" != *..* ]] || exit 1
  record="$config/acceptance-xcode-$XCODE_VERSION.json"
  jq -e --argjson configuration "$(cat "$config/xcode-$XCODE_VERSION.json")" \
    '.xcodeConfiguration == $configuration' "$record" >/dev/null
  tag="$tag-xcode$XCODE_VERSION"
fi
[[ "$tag" =~ ^[A-Za-z0-9][A-Za-z0-9._-]*$ ]] || exit 1
jq -e --argjson target "$(jq .target "$profile")" --arg variant "$VARIANT" '
  .target == $target and .variant == $variant and .anonymousDownloadVerified == true and
  .constructionVMStarted == false and .runtime.exitCode == 0 and .runtime.vmStopped == true and
  .runtime.sourceUnchanged == true and .runtime.rosettaInstalled == false and
  .runtime.manualGuestRepair == false
' "$record" >/dev/null
reference=$(jq -er .reference "$record")
repository="$(jq -er .repository "$profile")-$VARIANT"
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
printf 'Published %s at %s.\n\n' "$published" "$digest" >> "$GITHUB_STEP_SUMMARY"
