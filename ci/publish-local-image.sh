#!/usr/bin/env bash
set -euo pipefail

fail() { printf '%s\n' "$1" >&2; exit 1; }
safe_name() { [[ "$1" =~ ^[A-Za-z0-9][A-Za-z0-9._-]*$ && "$1" != *..* ]]; }

safe_name "${LOCAL_PUBLICATION:-}" || fail 'Invalid local publication ID.'
safe_name "${IMAGE_PROFILE:-}" || fail 'Invalid image profile.'
[[ ${VARIANT:-} == vanilla || ${VARIANT:-} == base || ${VARIANT:-} == xcode ]] || exit 1
[[ ${XCODE_FLAVOR:-full} == full || ${XCODE_FLAVOR:-full} == slim ]] || exit 1
[[ ${BEFORE_ACCEPTANCE:-false} == false ]] || fail 'Local publication requires acceptance.'
[[ ${REPLACE_EXISTING:-false} == false || ${REPLACE_EXISTING:-false} == true ]] || exit 1
root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
directory="$HOME/.local/share/macos-image/publications/$LOCAL_PUBLICATION"
record="$directory/acceptance.json"
profile="$root/config/miso/$IMAGE_PROFILE/profile.json"
[[ -f "$record" && ! -L "$record" && -f "$profile" ]] || fail 'Publication or profile is missing.'
source=$(cat "$directory/source-directory.txt")
[[ "$source" == /* && "$source" != *$'\n'* && "$source" != *$'\r'* && -d "$source" && ! -L "$source" ]] ||
  fail 'Invalid accepted source directory.'
for file in disk.img nvram.bin config.json; do
  [[ -f "$source/$file" && ! -L "$source/$file" ]] || fail 'Accepted source is incomplete.'
done
source_state() { stat -f '%i %z %b %.9Fm %.9Fc' "$source/"{disk.img,nvram.bin,config.json}; }
[[ "$(source_state)" == "$(cat "$directory/source-state.txt")" ]] || fail 'Accepted source changed.'
/bin/bash "$root/ci/shrink-image.sh" --check "$source" "$directory/disk-shrink.json"
jq -e --slurpfile shrink "$directory/disk-shrink.json" '.diskShrink == $shrink[0]' "$record" >/dev/null ||
  fail 'Acceptance does not cover the shrunk image.'

accepted_variant=$VARIANT
package_variant=$VARIANT
if [[ "$VARIANT" == xcode && ${XCODE_FLAVOR:-full} == slim ]]; then
  accepted_variant=xcode-slim
  package_variant=slim-xcode
fi
jq -e --argjson target "$(jq .target "$profile")" --arg variant "$accepted_variant" \
  --arg miso "${MISO_VERSION:?}" '
  .target == $target and .variant == $variant and .misoVersion == $miso and
  .reviewAccepted == true and .runtime.exitCode == 0 and .runtime.vmStarted == true and
  .runtime.vmStopped == true and .runtime.sourceUnchanged == true and
  (.runtime.checks | type == "array" and length > 0) and
  (if .acceptanceInheritance != null then
    . as $current | .acceptanceInheritance as $prior |
    .transformation == "disk-shrink" and .constructionVMStarted == false and
    .parentReference == .replacesReference and
    (.parentReference | type == "string" and test("@sha256:[0-9a-f]{64}$")) and
    $prior.reference == .parentReference and $prior.target == .target and
    ($prior | if .variant == "xcode" and .xcodeFlavor == "slim" then "xcode-slim"
              elif .variant == "xcode-full" then "xcode" else .variant end) == .variant and
    $prior.anonymousDownloadVerified == true and $prior.reviewAccepted != false and
    ($prior.acceptedAt | type == "string" and length > 0) and
    $prior.runtime.exitCode == 0 and $prior.runtime.vmStarted == true and
    $prior.runtime.vmStopped == true and $prior.runtime.sourceUnchanged == true and
    $prior.runtime.manualGuestRepair != true and
    ($prior.runtime.checks | type == "array" and length > 0) and
    (["original-requirements", "compile", "health", "final-desktop"] - $prior.runtime.checks | length == 0) and
    .runtime.validationScope == "disk-shrink" and
    (["cold-boot", "ssh", "filesystem-data", "filesystem-system"] - $current.runtime.checks | length == 0)
   else
    (.runtime.checks | index("credential-rotation-before-cold-boot") != null) and
    (.runtime.checks | index("credential-rotation-after-cold-boot") != null)
   end) and
  (.prerelease | type == "boolean") and
  (.customTag | type == "string" and test("^[A-Za-z0-9][A-Za-z0-9._-]{0,127}$"))
' "$record" >/dev/null || fail 'Local acceptance does not match the requested image.'
if [[ "$VARIANT" == xcode ]]; then
  safe_name "${XCODE_VERSION:-}" || exit 1
  jq -e --argjson xcode "$(cat "$root/config/miso/$IMAGE_PROFILE/xcode-$XCODE_VERSION.json")" '
    .xcodeConfiguration.version == $xcode.version and .xcodeConfiguration.build == $xcode.build and
    (if .acceptanceInheritance != null then
      .xcodeConfiguration == .acceptanceInheritance.xcodeConfiguration and
      (["xcode-tools", "xcode-gui"] - .acceptanceInheritance.runtime.checks | length == 0) and
      (.acceptanceInheritance.runtime.checks | any(.[]; startswith("simulator-")))
     else
      (.runtime.checks | index("runtime-startup") != null)
     end) and
    (if .transformation == "disk-shrink" and .constructionVMStarted == false then
      .componentInstallation == null and .parentReference == .replacesReference and
      (.replacesReference | type == "string" and test("@sha256:[0-9a-f]{64}$"))
     else
      .componentInstallation.completed == true and .componentInstallation.method == "xcodebuild" and
      .componentInstallation.vmStopped == true and .componentInstallation.sourceUnchanged == true
     end)
  ' "$record" >/dev/null || fail 'Local Xcode acceptance does not match the requested build.'
fi
repository="$(jq -er .repository "$profile")-$package_variant"
[[ "$repository" =~ ^ghcr\.io/minimillionaire/[a-z0-9][a-z0-9-]+$ ]] || exit 1
tag=$(jq -er .customTag "$record")
aliases=$(jq -ec --arg tag "$tag" '
  (.additionalTags // []) | select(type == "array" and length <= 8) |
  select(length == (unique | length)) |
  select(all(.[]; type == "string" and test("^[A-Za-z0-9_][A-Za-z0-9._-]{0,127}$") and . != $tag))
' "$record") || fail 'Invalid additional publication tags.'
published="$repository:$tag"
replacement=$(jq -r '.replacesReference // empty' "$record")
if [[ ${REPLACE_EXISTING:-false} == true ]]; then
  [[ "$replacement" == "$repository@sha256:"* && "${replacement##*@}" =~ ^sha256:[0-9a-f]{64}$ ]] ||
    fail 'Replacement publication requires the exact previous reference.'
else
  [[ -z "$replacement" ]] || fail 'Replacing a publication requires replace_existing.'
  [[ "$aliases" == '[]' ]] || fail 'Additional tags require an exact replacement reference.'
fi
[[ ${1:-} != --check ]] || { printf 'Accepted local source is unchanged: %s\n' "$published"; exit 0; }
[[ ${GITHUB_RUN_ID:-} =~ ^[0-9]+$ && ${GITHUB_RUN_ATTEMPT:-} =~ ^[0-9]+$ ]] || exit 1
[[ -n ${MISO_REGISTRY_USERNAME:-} && -n ${MISO_REGISTRY_PASSWORD:-} ]] || fail 'Registry credentials are missing.'
attempt="$directory/attempt-$GITHUB_RUN_ID-$GITHUB_RUN_ATTEMPT"
mkdir "$attempt"
registry_repository=${repository#ghcr.io/}
anonymous_token() {
  curl --fail --silent --show-error --proto '=https' --connect-timeout 30 --max-time 60 \
    --retry 2 --retry-max-time 90 --get --data-urlencode service=ghcr.io \
    --data-urlencode "scope=repository:$registry_repository:pull" https://ghcr.io/token | jq -er .token
}
anonymous=$(anonymous_token)
fetch_manifest() {
  curl --silent --show-error --proto '=https' --connect-timeout 30 --max-time 60 --max-filesize 4194304 \
    --header "Authorization: Bearer $anonymous" --header 'Accept: application/vnd.oci.image.manifest.v1+json' \
    --output "$attempt/manifest.json" --write-out '%{http_code}' "https://ghcr.io/v2/$registry_repository/manifests/$tag"
}
manifest_digest() { printf 'sha256:%s\n' "$(shasum -a 256 "$attempt/manifest.json" | awk '{print $1}')"; }
status=$(fetch_manifest)
upload=false
if [[ "$status" == 200 ]]; then
  receipt="$directory/upload-receipt.json"
  if [[ -f "$directory/publication.json" ]]; then receipt="$directory/publication.json"; fi
  if [[ -f "$receipt" ]]; then
    expected=$(jq -er --arg tag "$tag" 'select(.tag == $tag) | .reference' "$receipt")
    [[ "$expected" == "$repository@$(manifest_digest)" ]] || fail 'Target tag has a different digest.'
  elif [[ ${REPLACE_EXISTING:-false} == true && "$replacement" == "$repository@$(manifest_digest)" ]]; then
    upload=true
  else
    fail 'Target tag exists without matching replacement authorization or publication receipt.'
  fi
elif [[ "$status" == 404 ]]; then
  [[ ${REPLACE_EXISTING:-false} == false ]] || fail 'The publication being replaced no longer exists.'
  upload=true
else
  fail "Cannot inspect the target tag (HTTP $status)."
fi
if [[ "$upload" == true ]]; then
  labels=(--label "org.opencontainers.image.source=https://github.com/MiniMillionaire/macos-image"
    --label "org.opencontainers.image.revision=${GITHUB_SHA:?}"
    --label "dev.macos-image.version=$(jq -r .target.version "$record")"
    --label "dev.macos-image.build=$(jq -r .target.build "$record")"
    --label "dev.macos-image.publication-tag=$tag"
    --label "dev.macos-image.prerelease=$(jq -r .prerelease "$record")"
    --label "dev.macos-image.variant=$VARIANT" --label "dev.macos-image.miso=$MISO_VERSION")
  if [[ "$VARIANT" == xcode ]]; then
    labels+=(--label "dev.macos-image.xcode-flavor=${XCODE_FLAVOR:-full}"
      --label "dev.macos-image.xcode-version=$(jq -r .xcodeConfiguration.version "$record")"
      --label "dev.macos-image.xcode-build=$(jq -r .xcodeConfiguration.build "$record")")
  fi
  parent=$(jq -r '.parentReference // empty' "$record")
  if [[ -n "$parent" ]]; then
    [[ "$parent" =~ ^ghcr\.io/minimillionaire/[a-z0-9-]+@sha256:[0-9a-f]{64}$ ]] || exit 1
    labels+=(--label "dev.macos-image.parent=$parent")
  fi
  miso bundle push "$source" "$published" --output "$attempt/upload" --concurrency 4 \
    "${labels[@]}" > "$attempt/upload.json"
  expected=$(jq -er .reference "$attempt/upload.json")
  [[ "$expected" == "$repository@sha256:"* && "${expected##*@}" =~ ^sha256:[0-9a-f]{64}$ ]] || exit 1
  jq -n --arg reference "$expected" --arg tag "$tag" '{reference:$reference,tag:$tag}' > "$directory/upload-receipt.json.next"
  mv "$directory/upload-receipt.json.next" "$directory/upload-receipt.json"
  anonymous=$(anonymous_token)
  [[ $(fetch_manifest) == 200 && "$expected" == "$repository@$(manifest_digest)" ]] ||
    fail 'Published tag does not match the upload receipt.'
fi
if [[ "$aliases" != '[]' ]]; then
  printf '{}\n' > "$attempt/anonymous.json"
  while IFS= read -r alias; do
    previous=$(oras resolve "$repository:$alias" --registry-config "$attempt/anonymous.json")
    [[ "$previous" == "${expected##*@}" || "$previous" == "${replacement##*@}" ]] ||
      fail "Additional tag changed since acceptance: $alias"
    if [[ "$previous" != "${expected##*@}" ]]; then
      printf '%s' "$MISO_REGISTRY_PASSWORD" | oras tag "$expected" "$alias" \
        --username "$MISO_REGISTRY_USERNAME" --password-stdin --registry-config "$attempt/anonymous.json" \
        > "$attempt/alias-$alias.log"
    fi
    [[ $(oras resolve "$repository:$alias" --registry-config "$attempt/anonymous.json") == "${expected##*@}" ]] ||
      fail "Additional tag did not resolve to the accepted image: $alias"
  done < <(jq -r '.[]' <<< "$aliases")
fi
[[ "$(source_state)" == "$(cat "$directory/source-state.txt")" ]] || fail 'Source changed during publication.'
config_digest=$(jq -er .config.digest "$attempt/manifest.json")
[[ "$config_digest" =~ ^sha256:[0-9a-f]{64}$ ]] || exit 1
curl --fail --silent --show-error --location --proto '=https' --proto-redir '=https' \
  --connect-timeout 30 --max-time 60 --max-filesize 4194304 --header "Authorization: Bearer $anonymous" \
  --output "$attempt/config.json" "https://ghcr.io/v2/$registry_repository/blobs/$config_digest"
[[ "sha256:$(shasum -a 256 "$attempt/config.json" | awk '{print $1}')" == "$config_digest" &&
  $(stat -f %z "$attempt/config.json") == "$(jq -er .config.size "$attempt/manifest.json")" ]] ||
  fail 'Published image configuration failed verification.'
jq -n --arg reference "$expected" --arg tag "$tag" --argjson acceptance "$(cat "$record")" \
  --arg run "https://github.com/MiniMillionaire/macos-image/actions/runs/$GITHUB_RUN_ID" \
  '{status:"published",reference:$reference,tag:$tag,run:$run,acceptance:$acceptance,
    anonymousManifestVerified:true,anonymousConfigVerified:true}' > "$directory/publication.json.next"
mv "$directory/publication.json.next" "$directory/publication.json"
cp "$directory/publication.json" "$RUNNER_TEMP/local-publication.json"
printf 'Published %s at %s.\n' "$published" "${expected##*@}" >> "$GITHUB_STEP_SUMMARY"
