#!/usr/bin/env bash
set -euo pipefail

root_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
cd "$root_dir"
source ci/config.sh

repository=MiniMillionaire/macos-image
workflow=.github/workflows/image.yml

require_run_id() {
  [[ "$1" =~ ^[1-9][0-9]*-[1-9][0-9]*$ ]] || ci_die "Expected a run ID and attempt"
}

run_id_part() {
  printf '%s\n' "${1%-*}"
}

attempt_part() {
  printf '%s\n' "${1##*-}"
}

validate_run_json() {
  local run_json=$1
  local jobs_json=$2
  local expected_run=$3
  local expected_revision=$4
  local required_step=$5
  local run_id
  local attempt

  run_id=$(run_id_part "$expected_run")
  attempt=$(attempt_part "$expected_run")
  jq -e \
    --arg repository "$repository" \
    --arg workflow "$workflow" \
    --arg actor "$TRUSTED_ACTOR" \
    --arg revision "$expected_revision" \
    --argjson run_id "$run_id" \
    --argjson attempt "$attempt" '
      .id == $run_id and .run_attempt == $attempt and
      .repository.full_name == $repository and .path == $workflow and
      .event == "workflow_dispatch" and .head_branch == "main" and
      .head_sha == $revision and .status == "completed" and
      .actor.login == $actor and .triggering_actor.login == $actor
    ' "$run_json" >/dev/null || ci_die "Run $expected_run is not an authorized image run"

  jq -e \
    --arg revision "$expected_revision" \
    --arg step "$required_step" '
      any(.jobs[];
        .name == "Build, publish, or recover image" and
        .head_sha == $revision and
        any(.steps[]; .name == $step and .conclusion == "success"))
    ' "$jobs_json" >/dev/null || ci_die "Run $expected_run lacks successful $required_step evidence"
}

validate_metadata_file() {
  local path=$1
  [[ -f "$path" && ! -L "$path" ]] || ci_die "Missing recovery metadata: $path"
}

validate_source_run() {
  local stage=$1
  local revision=$2
  local step
  case "$stage" in
    built) step="Build and verify image" ;;
    prepared) step="Prepare image publication" ;;
    verified) step="Verify image digest" ;;
    published)
      validate_run_json "$SOURCE_RUN_JSON" "$SOURCE_JOBS_JSON" "$SOURCE_RUN" "$revision" "Verify image digest"
      step="Promote image tags"
      ;;
    *) ci_die "Unknown source stage: $stage" ;;
  esac
  validate_run_json "$SOURCE_RUN_JSON" "$SOURCE_JOBS_JSON" "$SOURCE_RUN" "$revision" "$step"
}

validate_bundle_metadata() {
  local path=$1
  local build_run=$2
  local revision=$3
  validate_metadata_file "$path"
  jq -e \
    --arg repository "$repository" \
    --arg build_run "$build_run" \
    --arg revision "$revision" \
    --arg profile "$PROFILE" \
    --arg variant "$VARIANT_ID" \
    --arg config_sha "$PROFILE_CONFIG_SHA256" \
    --arg tools_sha "$TOOLCHAIN_CONFIG_SHA256" '
      .format == 1 and .repository == $repository and .build_run == $build_run and
      .revision == $revision and .profile == $profile and .variant == $variant and
      .config_sha256 == $config_sha and .toolchain_sha256 == $tools_sha and
      ([.files[].path] | sort) == ["config.json", "disk.img", "nvram.bin"] and
      all(.files[];
        (.size | type == "number" and . >= 0) and
        (.sha256 | test("^[0-9a-f]{64}$")))
    ' "$path" >/dev/null || ci_die "Saved VM bundle metadata does not match this request"
}

validate_prepared_metadata() {
  local directory=$1
  local result=$2
  local stage
  local digest
  stage=$(jq -er .stage "$result")
  if [[ "$stage" != prepared && "$stage" != verified && "$stage" != published ]]; then
    return 0
  fi
  validate_metadata_file "$directory/inspect.json"
  validate_metadata_file "$directory/oci-manifest.json"
  digest=$(jq -er .manifest_digest "$result")
  [[ "$digest" =~ ^sha256:[0-9a-f]{64}$ ]] || ci_die "Invalid saved manifest digest"
  [[ "sha256:$(ci_sha256 "$directory/oci-manifest.json")" == "$digest" ]] || ci_die "Saved OCI manifest digest changed"
  jq -e \
    --arg digest "$digest" \
    --arg revision "$(jq -er .revision "$result")" \
    --arg macos_version "$MACOS_VERSION" \
    --arg macos_build "$MACOS_BUILD" \
    --arg variant "$VARIANT" \
    --arg xcode "${XCODE_VERSION:-}" \
    --arg source "https://github.com/$repository" '
      .manifest_digest == $digest and .revision == $revision and
      .macos_version == $macos_version and
      .macos_build == $macos_build and .variant == $variant and
      ((.xcode_version // "") == $xcode) and .source == $source
    ' "$directory/inspect.json" >/dev/null || ci_die "Saved OCI metadata does not match this request"
}

validate_common_result() {
  local inputs=$1
  local result=$2

  jq -e \
    --arg repository "$repository" \
    --arg workflow "$workflow" \
    --arg profile "$PROFILE" \
    --arg flavor "$PACKAGE_FLAVOR" \
    --arg config "$CONFIG_PATH" \
    --arg config_sha "$PROFILE_CONFIG_SHA256" \
    --arg tools_sha "$TOOLCHAIN_CONFIG_SHA256" \
    --arg macos_family "$MACOS_FAMILY" \
    --arg macos_version "$MACOS_VERSION" \
    --arg macos_build "$MACOS_BUILD" \
    --argjson prerelease "$IMAGE_PRERELEASE" \
    --arg variant "$VARIANT" \
    --arg variant_id "$VARIANT_ID" \
    --arg xcode "${XCODE_VERSION:-}" \
    --arg xcode_tag "$XCODE_TAG" \
    --argjson update_latest "$UPDATE_LATEST" \
    --arg package "$PACKAGE_REF" '
      .format == 1 and .repository == $repository and .workflow == $workflow and
      .profile == $profile and (.flavor // "standard") == $flavor and .config == $config and
      .config_sha256 == $config_sha and .toolchain_sha256 == $tools_sha and
      .macos == {family: $macos_family, version: $macos_version, build: $macos_build} and
      .prerelease == $prerelease and
      .variant == $variant and .variant_id == $variant_id and
      .xcode_version == $xcode and .xcode_tag == $xcode_tag and
      .update_latest == $update_latest and .package_reference == $package
    ' "$inputs" >/dev/null || ci_die "Saved inputs do not match this request"

  jq -e \
    --arg repository "$repository" \
    --arg profile "$PROFILE" \
    --arg variant "$VARIANT" \
    --arg variant_id "$VARIANT_ID" \
    --arg xcode "${XCODE_VERSION:-}" \
    --arg xcode_tag "$XCODE_TAG" \
    --argjson update_latest "$UPDATE_LATEST" \
    --arg macos_version "$MACOS_VERSION" \
    --arg macos_build "$MACOS_BUILD" \
    --arg package "$PACKAGE_REF" '
      .format == 1 and .result == "passed" and .repository == $repository and
      .profile == $profile and .variant == $variant and .variant_id == $variant_id and
      .xcode_version == $xcode and .xcode_tag == $xcode_tag and .update_latest == $update_latest and
      .macos_version == $macos_version and .macos_build == $macos_build and
      .package_reference == $package and
      (.revision | test("^[0-9a-f]{40}$")) and
      (.run_id | test("^[1-9][0-9]*-[1-9][0-9]*$")) and
      (.build_run | test("^[1-9][0-9]*-[1-9][0-9]*$"))
    ' "$result" >/dev/null || ci_die "Saved result does not match this request"

  [[ $(jq -er .revision "$inputs") == "$(jq -er .revision "$result")" ]] || ci_die "Saved input and result revisions differ"
  [[ $(jq -er .run_id "$inputs") == "$(jq -er .run_id "$result")" ]] || ci_die "Saved input and result run IDs differ"
  jq -e '(.workflow_revision | test("^[0-9a-f]{40}$"))' "$inputs" >/dev/null || ci_die "Saved workflow revision is invalid"
}

authorize_current() {
  ci_load_profile
  case ${OPERATION:-} in
    build|publish|upload-only|recover-upload|recover-release) ;;
    *) ci_die "Unknown operation: ${OPERATION:-}" ;;
  esac

  [[ ${GITHUB_REPOSITORY:-} == "$repository" ]] || ci_die "This workflow only runs in $repository"
  [[ ${GITHUB_REF:-} == refs/heads/main ]] || ci_die "Image runs must be dispatched from main"
  [[ ${GITHUB_ACTOR:-} == "$TRUSTED_ACTOR" ]] || ci_die "The original actor is not trusted"
  [[ ${GITHUB_TRIGGERING_ACTOR:-} == "$TRUSTED_ACTOR" ]] || ci_die "The current rerun actor is not trusted"
  [[ ${GITHUB_SHA:-} =~ ^[0-9a-f]{40}$ ]] || ci_die "Invalid workflow revision"
  git merge-base --is-ancestor "$GITHUB_SHA" origin/main || ci_die "Workflow revision is not on main"

  if [[ "$OPERATION" == upload-only || "$OPERATION" == recover-upload || "$OPERATION" == recover-release ]]; then
    require_run_id "${SOURCE_RUN:-}"
  else
    [[ -z ${SOURCE_RUN:-} ]] || ci_die "Source run applies only to recovery operations"
  fi
  [[ "$OPERATION" != recover-release || "$VARIANT" == xcode ]] || ci_die "Only Xcode images have GitHub releases"
  [[ "$OPERATION" != recover-release || "$PACKAGE_FLAVOR" == standard ]] || ci_die "Slim images do not use GitHub releases"

  ci_write_output profile "$PROFILE"
  ci_write_output flavor "$PACKAGE_FLAVOR"
  ci_write_output config "$CONFIG_PATH"
  ci_write_output operation "$OPERATION"
  ci_write_output variant "$VARIANT"
  ci_write_output variant_id "$VARIANT_ID"
  ci_write_output xcode_version "${XCODE_VERSION:-}"
  ci_write_output xcode_tag "$XCODE_TAG"
  ci_write_output update_latest "$UPDATE_LATEST"
  ci_write_output package_ref "$PACKAGE_REF"
  ci_write_output go_version "$GO_VERSION"
  if [[ -n ${SOURCE_RUN:-} ]]; then
    ci_write_output source_run_id "$(run_id_part "$SOURCE_RUN")"
    ci_write_output source_run_attempt "$(attempt_part "$SOURCE_RUN")"
  fi
}

read_source_metadata() {
  ci_load_profile
  local inputs="$SOURCE_ARTIFACT_DIR/inputs.json"
  local result="$SOURCE_ARTIFACT_DIR/result.json"
  validate_metadata_file "$inputs"
  validate_metadata_file "$result"
  validate_common_result "$inputs" "$result"

  local revision
  local build_run
  local source_stage
  local workflow_revision
  revision=$(jq -er .revision "$result")
  build_run=$(jq -er .build_run "$result")
  source_stage=$(jq -er .stage "$result")
  workflow_revision=$(jq -er .workflow_revision "$inputs")
  [[ $(jq -er .run_id "$result") == "$SOURCE_RUN" ]] || ci_die "Source metadata has the wrong run ID"
  validate_source_run "$source_stage" "$workflow_revision"
  validate_bundle_metadata "$SOURCE_ARTIFACT_DIR/bundle.json" "$build_run" "$revision"
  validate_prepared_metadata "$SOURCE_ARTIFACT_DIR" "$result"
  git merge-base --is-ancestor "$revision" origin/main || ci_die "Saved revision is not on main"

  ci_write_output revision "$revision"
  ci_write_output build_run "$build_run"
  ci_write_output build_run_id "$(run_id_part "$build_run")"
  ci_write_output build_run_attempt "$(attempt_part "$build_run")"
  ci_write_output source_inputs_sha256 "$(ci_sha256 "$inputs")"
  ci_write_output source_result_sha256 "$(ci_sha256 "$result")"
  ci_write_output bundle_metadata_sha256 "$(ci_sha256 "$SOURCE_ARTIFACT_DIR/bundle.json")"
}

authorize_recovery() {
  ci_load_profile
  local source_inputs="$SOURCE_ARTIFACT_DIR/inputs.json"
  local source_result="$SOURCE_ARTIFACT_DIR/result.json"
  local build_inputs="$BUILD_ARTIFACT_DIR/inputs.json"
  local build_result="$BUILD_ARTIFACT_DIR/result.json"
  local revision
  local build_run
  local source_stage
  local source_workflow_revision

  for path in "$source_inputs" "$source_result" "$build_inputs" "$build_result"; do
    validate_metadata_file "$path"
  done
  validate_common_result "$source_inputs" "$source_result"
  validate_common_result "$build_inputs" "$build_result"
  revision=$(jq -er .revision "$source_result")
  build_run=$(jq -er .build_run "$source_result")
  source_stage=$(jq -er .stage "$source_result")
  source_workflow_revision=$(jq -er .workflow_revision "$source_inputs")

  [[ $(jq -er .run_id "$source_result") == "$SOURCE_RUN" ]] || ci_die "Source metadata has the wrong run ID"

  [[ $(jq -er .revision "$build_result") == "$revision" ]] || ci_die "Build and source revisions differ"
  [[ $(jq -er .run_id "$build_result") == "$build_run" ]] || ci_die "Original build metadata has the wrong run ID"
  [[ $(jq -er .build_run "$build_result") == "$build_run" ]] || ci_die "Original build metadata is not self-contained"
  [[ $(jq -er .stage "$build_result") =~ ^(built|prepared|verified|published)$ ]] || ci_die "Original build did not pass"
  validate_bundle_metadata "$SOURCE_ARTIFACT_DIR/bundle.json" "$build_run" "$revision"
  validate_bundle_metadata "$BUILD_ARTIFACT_DIR/bundle.json" "$build_run" "$revision"
  [[ $(ci_sha256 "$SOURCE_ARTIFACT_DIR/bundle.json") == "$(ci_sha256 "$BUILD_ARTIFACT_DIR/bundle.json")" ]] ||
    ci_die "Source VM metadata differs from the original build artifact"
  validate_prepared_metadata "$SOURCE_ARTIFACT_DIR" "$source_result"

  validate_source_run "$source_stage" "$source_workflow_revision"
  validate_run_json "$BUILD_RUN_JSON" "$BUILD_JOBS_JSON" "$build_run" "$revision" "Build and verify image"

  if [[ "$OPERATION" == upload-only || "$OPERATION" == recover-upload ]]; then
    [[ "$source_stage" == built || "$source_stage" == prepared || "$source_stage" == verified ]] ||
      ci_die "Upload recovery requires a built, prepared, or verified image"
  else
    [[ "$source_stage" == published ]] || ci_die "Release recovery requires a published image"
    for path in publication.json image-spec.json oci-manifest.json; do
      validate_metadata_file "$SOURCE_ARTIFACT_DIR/$path"
    done
  fi

  ci_write_output revision "$revision"
  ci_write_output build_run "$build_run"
  ci_write_output source_inputs_sha256 "$(ci_sha256 "$source_inputs")"
  ci_write_output source_result_sha256 "$(ci_sha256 "$source_result")"
  ci_write_output bundle_metadata_sha256 "$(ci_sha256 "$SOURCE_ARTIFACT_DIR/bundle.json")"
  ci_write_output publication_run "$([[ "$OPERATION" == recover-release ]] && printf '%s' "$SOURCE_RUN" || printf '%s-%s' "$GITHUB_RUN_ID" "$GITHUB_RUN_ATTEMPT")"
  ci_write_output publication_run_id "$([[ "$OPERATION" == recover-release ]] && run_id_part "$SOURCE_RUN" || printf '%s' "$GITHUB_RUN_ID")"
}

case ${1:-} in
  current) authorize_current ;;
  source-metadata) read_source_metadata ;;
  recovery) authorize_recovery ;;
  *) ci_die "Usage: ci/authorize.sh <current|source-metadata|recovery>" ;;
esac
