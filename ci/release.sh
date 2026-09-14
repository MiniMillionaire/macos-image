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

for path in "$inputs" "$result" "$publication" "$spec" "$manifest" "$inspect"; do
  [[ -f "$path" && ! -L "$path" ]] || ci_die "Missing publication file: $path"
done
[[ -f "$artifact/verify.log" && ! -L "$artifact/verify.log" ]] || ci_die "Missing published guest log"
if [[ -n ${EXPECTED_INPUTS_SHA256:-} ]]; then
  [[ $(ci_sha256 "$inputs") == "$EXPECTED_INPUTS_SHA256" ]] || ci_die "Publication inputs changed after authorization"
  [[ $(ci_sha256 "$result") == "$EXPECTED_RESULT_SHA256" ]] || ci_die "Publication result changed after authorization"
fi

revision=$(jq -er .revision "$result")
digest=$(jq -er .manifest_digest "$result")
[[ "$revision" =~ ^[0-9a-f]{40}$ ]] || ci_die "Invalid publication revision"
[[ "$digest" =~ ^sha256:[0-9a-f]{64}$ ]] || ci_die "Invalid publication digest"
[[ $(git rev-parse --verify "refs/tags/$RELEASE_TAG^{commit}") == "$revision" ]] || ci_die "Release tag does not point to the image revision"
git merge-base --is-ancestor "$revision" origin/main || ci_die "Image revision is not on main"

jq -e \
  --arg repository "$repository" \
  --arg profile "$PROFILE" \
  --arg config "$CONFIG_PATH" \
  --arg config_sha "$PROFILE_CONFIG_SHA256" \
  --arg tools_sha "$TOOLCHAIN_CONFIG_SHA256" \
  --arg variant "$VARIANT" \
  --arg variant_id "$VARIANT_ID" \
  --arg xcode "${XCODE_VERSION:-}" \
  --arg tag "$IMAGE_TAG" \
  --arg release_tag "$RELEASE_TAG" \
  --arg package "$PACKAGE_REF" \
  --arg revision "$revision" '
    .format == 1 and .repository == $repository and
    .profile == $profile and .config == $config and
    .config_sha256 == $config_sha and .toolchain_sha256 == $tools_sha and
    .variant == $variant and .variant_id == $variant_id and
    .xcode_version == $xcode and .image_tag == $tag and
    .release_tag == $release_tag and .package_reference == $package and
    .revision == $revision
  ' "$inputs" >/dev/null || ci_die "Publication inputs do not match the release"

jq -e \
  --arg repository "$repository" \
  --arg run "$PUBLICATION_RUN" \
  --arg revision "$revision" \
  --arg profile "$PROFILE" \
  --arg variant "$VARIANT" \
  --arg variant_id "$VARIANT_ID" \
  --arg xcode "${XCODE_VERSION:-}" \
  --arg image_version "$IMAGE_VERSION" \
  --arg macos_version "$MACOS_VERSION" \
  --arg macos_build "$MACOS_BUILD" \
  --arg release_tag "$RELEASE_TAG" \
  --arg package "$PACKAGE_REF" \
  --arg digest "$digest" '
    .format == 1 and .result == "passed" and .stage == "published" and
    .repository == $repository and .run_id == $run and .revision == $revision and
    .profile == $profile and .variant == $variant and .variant_id == $variant_id and
    .xcode_version == $xcode and .image_version == $image_version and
    .macos_version == $macos_version and .macos_build == $macos_build and
    .release_tag == $release_tag and .package_reference == $package and
    .manifest_digest == $digest
  ' "$result" >/dev/null || ci_die "Publication result does not match the release"

jq -e \
  --arg run "$PUBLICATION_RUN" \
  --arg revision "$revision" \
  --arg reference "$PACKAGE_REF" \
  --arg digest "$digest" '
    .format == 1 and .publication_run == $run and .revision == $revision and
    .reference == $reference and .digest == $digest and
    .anonymous_download == "passed" and .import == "passed" and .guest_test == "passed"
  ' "$publication" >/dev/null || ci_die "Anonymous publication verification did not pass"

[[ "sha256:$(ci_sha256 "$manifest")" == "$digest" ]] || ci_die "OCI manifest digest changed"
grep -Fx "Verified image profile: $VARIANT" "$artifact/verify.log" >/dev/null || ci_die "Published guest profile verification is missing"
grep -Eq '^Boot session: [0-9A-Fa-f-]+$' "$artifact/verify.log" || ci_die "Published guest boot evidence is missing"
jq -e \
  --arg digest "$digest" \
  --arg revision "$revision" \
  --arg image_version "$IMAGE_VERSION" \
  --arg macos_version "$MACOS_VERSION" \
  --arg macos_build "$MACOS_BUILD" \
  --arg variant "$VARIANT" \
  --arg xcode "${XCODE_VERSION:-}" \
  --arg source "https://github.com/$repository" '
    .manifest_digest == $digest and .revision == $revision and
    .image_version == $image_version and .macos_version == $macos_version and
    .macos_build == $macos_build and .variant == $variant and
    ((.xcode_version // "") == $xcode) and .source == $source and
    (.manifest_size | type == "number" and . > 0) and
    (.blob_bytes | type == "number" and . > 0)
  ' "$inspect" >/dev/null || ci_die "OCI inspection does not match the release"
jq -e \
  --arg reference "${PACKAGE_REF%:*}@$digest" \
  --arg image_version "$IMAGE_VERSION" \
  --arg macos_family "$MACOS_FAMILY" \
  --arg macos_version "$MACOS_VERSION" \
  --arg macos_build "$MACOS_BUILD" \
  --arg variant "$VARIANT" \
  --arg variant_id "$VARIANT_ID" \
  --arg xcode "${XCODE_VERSION:-}" '
    .format == 1 and .image_version == $image_version and
    .macos == {family: $macos_family, version: $macos_version, build: $macos_build, architecture: "arm64"} and
    .variant == $variant and .variant_id == $variant_id and .xcode_version == $xcode and
    .source == {type: "prebuilt", reference: $reference}
  ' "$spec" >/dev/null || ci_die "Image specification does not match the publication"

unset TART_REGISTRY_HOSTNAME TART_REGISTRY_USERNAME TART_REGISTRY_PASSWORD
[[ $(./scripts/registry check "$PACKAGE_REF" "$digest") == present ]] || ci_die "Published registry digest is not anonymously readable"

notes="$RUNNER_TEMP/macos-image-release-notes.md"
cat > "$notes" <<EOF
Verified arm64 macOS $MACOS_VERSION ($MACOS_BUILD) $VARIANT_ID image.

The published image was downloaded anonymously, imported into Tart, and passed an independent guest test.

\`\`\`sh
tart clone ${PACKAGE_REF%:*}@$digest macos-$MACOS_FAMILY-$VARIANT_ID
\`\`\`
EOF

options=()
if [[ "$IMAGE_PRERELEASE" == true ]]; then
  options+=(--prerelease --latest=false)
fi

gh release create "$RELEASE_TAG" --repo "$repository" --verify-tag \
  --title "macOS $MACOS_VERSION ($MACOS_BUILD) $VARIANT_ID, image $IMAGE_VERSION" \
  --notes-file "$notes" "${options[@]}" \
  "$inputs" "$result" "$publication" "$spec" "$manifest" "$inspect"
