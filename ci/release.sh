#!/usr/bin/env bash
set -euo pipefail

root_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
cd "$root_dir"
source ci/config.sh
ci_load_profile

repository=MiniMillionaire/macos-image
artifact=${PUBLICATION_ARTIFACT_DIR:?}
inputs="$artifact/inputs.json"
result="$artifact/result.json"
publication="$artifact/publication.json"
spec="$artifact/image-spec.json"
manifest="$artifact/oci-manifest.json"
inspect="$artifact/inspect.json"

[[ "$VARIANT" == xcode ]] || ci_die "Only Xcode images have GitHub releases"
for path in "$inputs" "$result" "$publication" "$spec" "$manifest" "$inspect" "$artifact/verify.log"; do
  [[ -f "$path" && ! -L "$path" ]] || ci_die "Missing publication file: $path"
done
if [[ -n ${EXPECTED_INPUTS_SHA256:-} ]]; then
  [[ $(ci_sha256 "$inputs") == "$EXPECTED_INPUTS_SHA256" ]] || ci_die "Publication inputs changed after authorization"
  [[ $(ci_sha256 "$result") == "$EXPECTED_RESULT_SHA256" ]] || ci_die "Publication result changed after authorization"
fi

revision=$(jq -er .revision "$result")
digest=$(jq -er .manifest_digest "$result")
digest_ref="${PACKAGE_REF%:*}@$digest"
[[ "$revision" =~ ^[0-9a-f]{40}$ ]] || ci_die "Invalid publication revision"
[[ "$digest" =~ ^sha256:[0-9a-f]{64}$ ]] || ci_die "Invalid publication digest"
git merge-base --is-ancestor "$revision" origin/main || ci_die "Image revision is not on main"

jq -e \
  --arg repository "$repository" \
  --arg profile "$PROFILE" \
  --arg config "$CONFIG_PATH" \
  --arg config_sha "$PROFILE_CONFIG_SHA256" \
  --arg tools_sha "$TOOLCHAIN_CONFIG_SHA256" \
  --arg macos_family "$MACOS_FAMILY" \
  --arg macos_version "$MACOS_VERSION" \
  --arg macos_build "$MACOS_BUILD" \
  --argjson prerelease "$IMAGE_PRERELEASE" \
  --arg variant "$VARIANT" \
  --arg variant_id "$VARIANT_ID" \
  --arg xcode "$XCODE_VERSION" \
  --arg xcode_tag "$XCODE_TAG" \
  --argjson update_latest "$UPDATE_LATEST" \
  --arg package "$PACKAGE_REF" \
  --arg latest "$LATEST_REF" \
  --arg revision "$revision" '
    .format == 1 and .repository == $repository and
    .profile == $profile and .config == $config and
    .config_sha256 == $config_sha and .toolchain_sha256 == $tools_sha and
    .macos == {family: $macos_family, version: $macos_version, build: $macos_build} and
    .prerelease == $prerelease and
    .variant == $variant and .variant_id == $variant_id and
    .xcode_version == $xcode and .xcode_tag == $xcode_tag and
    .update_latest == $update_latest and .package_reference == $package and
    .latest_reference == $latest and .revision == $revision
  ' "$inputs" >/dev/null || ci_die "Publication inputs do not match the release"

jq -e \
  --arg repository "$repository" \
  --arg run "$PUBLICATION_RUN" \
  --arg revision "$revision" \
  --arg profile "$PROFILE" \
  --arg variant "$VARIANT" \
  --arg variant_id "$VARIANT_ID" \
  --arg xcode "$XCODE_VERSION" \
  --arg xcode_tag "$XCODE_TAG" \
  --argjson update_latest "$UPDATE_LATEST" \
  --arg macos_version "$MACOS_VERSION" \
  --arg macos_build "$MACOS_BUILD" \
  --arg package "$PACKAGE_REF" \
  --arg latest "$LATEST_REF" \
  --arg digest "$digest" '
    .format == 1 and .result == "passed" and .stage == "published" and
    .repository == $repository and .run_id == $run and .revision == $revision and
    .profile == $profile and .variant == $variant and .variant_id == $variant_id and
    .xcode_version == $xcode and .xcode_tag == $xcode_tag and .update_latest == $update_latest and
    .macos_version == $macos_version and .macos_build == $macos_build and
    .package_reference == $package and .latest_reference == $latest and
    .manifest_digest == $digest
  ' "$result" >/dev/null || ci_die "Publication result does not match the release"

latest_status=skipped
[[ "$UPDATE_LATEST" == false ]] || latest_status=passed
jq -e \
  --arg run "$PUBLICATION_RUN" \
  --arg build_run "$(jq -er .build_run "$result")" \
  --arg revision "$revision" \
  --arg digest_reference "$digest_ref" \
  --arg tag_reference "$PACKAGE_REF" \
  --arg latest_reference "$LATEST_REF" \
  --arg digest "$digest" \
  --arg latest_status "$latest_status" '
    .format == 1 and .publication_run == $run and .build_run == $build_run and
    .revision == $revision and .digest_reference == $digest_reference and
    .tag_reference == $tag_reference and .latest_reference == $latest_reference and
    .digest == $digest and .anonymous_download == "passed" and
    .import == "passed" and .guest_test == "passed" and
    .tag_promotion == "passed" and .latest_promotion == $latest_status
  ' "$publication" >/dev/null || ci_die "Publication verification did not pass"

[[ "sha256:$(ci_sha256 "$manifest")" == "$digest" ]] || ci_die "OCI manifest digest changed"
verification_output=$(sed -n $'s/\033\\[[0-9;]*m//g; s/^==> tart-cli\\.verify: //p' "$artifact/verify.log")
grep -Fx "Verified image profile: $VARIANT" <<< "$verification_output" >/dev/null || ci_die "Published guest profile verification is missing"
grep -Eq '^Boot session: [0-9A-Fa-f-]+$' <<< "$verification_output" || ci_die "Published guest boot evidence is missing"
jq -e \
  --arg digest "$digest" \
  --arg revision "$revision" \
  --arg macos_version "$MACOS_VERSION" \
  --arg macos_build "$MACOS_BUILD" \
  --arg variant "$VARIANT" \
  --arg xcode "$XCODE_VERSION" \
  --arg source "https://github.com/$repository" '
    .manifest_digest == $digest and .revision == $revision and
    .macos_version == $macos_version and .macos_build == $macos_build and
    .variant == $variant and ((.xcode_version // "") == $xcode) and .source == $source and
    (.manifest_size | type == "number" and . > 0) and
    (.blob_bytes | type == "number" and . > 0)
  ' "$inspect" >/dev/null || ci_die "OCI inspection does not match the release"
jq -e \
  --arg reference "$digest_ref" \
  --arg macos_family "$MACOS_FAMILY" \
  --arg macos_version "$MACOS_VERSION" \
  --arg macos_build "$MACOS_BUILD" \
  --arg variant "$VARIANT" \
  --arg variant_id "$VARIANT_ID" \
  --arg xcode "$XCODE_VERSION" \
  --arg xcode_tag "$XCODE_TAG" \
  --argjson update_latest "$UPDATE_LATEST" '
    .format == 1 and
    .macos == {family: $macos_family, version: $macos_version, build: $macos_build, architecture: "arm64"} and
    .variant == $variant and .variant_id == $variant_id and .xcode_version == $xcode and
    .xcode_tag == $xcode_tag and .update_latest == $update_latest and
    .source == {type: "prebuilt", reference: $reference}
  ' "$spec" >/dev/null || ci_die "Image specification does not match the publication"

unset TART_REGISTRY_HOSTNAME TART_REGISTRY_USERNAME TART_REGISTRY_PASSWORD
[[ $(./scripts/registry check "$digest_ref" "$digest") == present ]] || ci_die "Published digest is not anonymously readable"
[[ $(./scripts/registry check "$PACKAGE_REF" "$digest") == present ]] || ci_die "Published tag does not match the verified digest"
if [[ -n "$LATEST_REF" ]]; then
  [[ $(./scripts/registry check "$LATEST_REF" "$digest") == present ]] || ci_die "Latest tag does not match the verified digest"
fi

scratch=$(mktemp -d "$RUNNER_TEMP/macos-image-release.XXXXXX")
trap 'rm -rf -- "$scratch"' EXIT
notes="$scratch/notes.md"
cat > "$notes" <<EOF
Verified arm64 Xcode $XCODE_TAG images.

Each asset set records the source and OCI digest for one macOS profile. Published images were downloaded by digest, imported into Tart, and cold-boot tested before their tags were promoted.
EOF

release_json="$scratch/release.json"
tag_revision=
if git show-ref --verify --quiet "refs/tags/$RELEASE_TAG"; then
  tag_revision=$(git rev-parse --verify "refs/tags/$RELEASE_TAG^{commit}")
  git merge-base --is-ancestor "$tag_revision" origin/main || ci_die "Existing Xcode tag is not on main"
fi
if ! gh release view "$RELEASE_TAG" --repo "$repository" --json tagName,isDraft,isPrerelease > "$release_json" 2> "$scratch/release-view.log"; then
  options=("$RELEASE_TAG" --repo "$repository" --title "Xcode $XCODE_TAG images" --notes-file "$notes")
  if [[ "$XCODE_PRERELEASE" == true ]]; then
    options+=(--prerelease --latest=false)
  fi
  if [[ -n "$tag_revision" ]]; then
    gh release create "${options[@]}" --verify-tag ||
      ci_die "Could not create the release from the existing Xcode tag"
  else
    gh release create "${options[@]}" --target "$revision" ||
      ci_die "Could not create the Xcode tag and release at the verified revision"
  fi
  gh release view "$RELEASE_TAG" --repo "$repository" --json tagName,isDraft,isPrerelease > "$release_json"
elif [[ -z "$tag_revision" ]]; then
  ci_die "Existing Xcode release tag is missing from the checkout"
fi

jq -e --arg tag "$RELEASE_TAG" --argjson prerelease "$XCODE_PRERELEASE" '
  .tagName == $tag and .isDraft == false and .isPrerelease == $prerelease
' "$release_json" >/dev/null || ci_die "Existing Xcode release has incompatible settings"

assets_json="$scratch/assets.json"
gh release view "$RELEASE_TAG" --repo "$repository" --json assets > "$assets_json"
asset_prefix="$PROFILE-$MACOS_BUILD-${digest#sha256:}-$PUBLICATION_RUN"
uploads=()
for path in "$inputs" "$result" "$publication" "$spec" "$manifest" "$inspect" "$artifact/verify.log"; do
  name="$asset_prefix-${path##*/}"
  local_path="$scratch/$name"
  cp "$path" "$local_path"
  if jq -e --arg name "$name" 'any(.assets[]; .name == $name)' "$assets_json" >/dev/null; then
    remote="$scratch/remote-$name"
    mkdir "$remote"
    gh release download "$RELEASE_TAG" --repo "$repository" --pattern "$name" --dir "$remote"
    [[ $(ci_sha256 "$remote/$name") == "$(ci_sha256 "$local_path")" ]] || ci_die "Release asset already exists with different contents: $name"
  else
    uploads+=("$local_path")
  fi
done
if (( ${#uploads[@]} > 0 )); then
  gh release upload "$RELEASE_TAG" --repo "$repository" "${uploads[@]}"
fi

verified="$scratch/verified"
mkdir "$verified"
gh release download "$RELEASE_TAG" --repo "$repository" --pattern "$asset_prefix-*" --dir "$verified"
for path in "$scratch/$asset_prefix-"*; do
  name=${path##*/}
  [[ $(ci_sha256 "$verified/$name") == "$(ci_sha256 "$path")" ]] || ci_die "Uploaded release asset changed: $name"
done
