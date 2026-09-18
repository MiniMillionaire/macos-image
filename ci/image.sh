#!/usr/bin/env bash
set -euo pipefail

root_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
cd "$root_dir"
source ci/config.sh
ci_load_profile

repository=MiniMillionaire/macos-image
repository_url=https://github.com/MiniMillionaire/macos-image
workflow=.github/workflows/image.yml
run_key="$GITHUB_RUN_ID-$GITHUB_RUN_ATTEMPT"
task_root="$RUNNER_TEMP/macos-image-$run_key"
marker="$task_root/.ci-task"
logs="$task_root/logs"
tart_home="$task_root/tart"
vm_name="macos-image-$run_key"
source_vm="$vm_name-source"
published_vm="$vm_name-published"
layout="$task_root/publication/layout"
verified_root="$HOME/.cache/macos-image/verified/minimillionaire-macos-image"
source ci/parent-cache.sh

export IMAGE_CONFIG="$CONFIG_PATH"
export IMAGE_CACERT
export IMAGE_VARIANT="$VARIANT"
if [[ -z "$VANILLA_SOURCE_PROFILE" ]]; then
  export IPSW_PATH="$task_root/restore.ipsw"
else
  unset IPSW_PATH
fi
export PACKER_CONFIG="$root_dir/config/packer.json"
export REGISTRY
export TART_HOME="$tart_home"
export TART_NO_AUTO_PRUNE=1
export INSTALLER_CACHE_DIR="${INSTALLER_CACHE_DIR:-$HOME/.cache/macos-image/installers}"
export XCODE_VERSION="${XCODE_VERSION:-}"
export XCODE_TAG

expected_marker() {
  jq -cn \
    --arg repository "$repository" \
    --arg run "$run_key" \
    --arg profile "$PROFILE" \
    --arg variant "$VARIANT_ID" \
    '{format: 1, repository: $repository, run: $run, profile: $profile, variant: $variant}'
}

require_task() {
  [[ "$task_root" == "$RUNNER_TEMP/macos-image-$run_key" ]] || ci_die "Invalid task path"
  [[ -f "$marker" && ! -L "$marker" ]] || ci_die "Task marker is missing"
  [[ $(jq -cS . "$marker") == "$(expected_marker | jq -cS .)" ]] || ci_die "Task marker does not match this run"
}

verified_directory() {
  local build_run=$1
  [[ "$build_run" =~ ^[1-9][0-9]*-[1-9][0-9]*$ ]] || ci_die "Invalid build run"
  printf '%s/%s/%s/%s\n' "$verified_root" "$PROFILE" "$VARIANT_ID" "$build_run"
}

require_verified_path() {
  local directory=$1
  [[ "$directory" == "$verified_root/$PROFILE/$VARIANT_ID/"* ]] || ci_die "Invalid verified cache path"
  for ancestor in "$HOME/.cache" "$HOME/.cache/macos-image" "$HOME/.cache/macos-image/verified" "$verified_root" "$verified_root/$PROFILE" "$verified_root/$PROFILE/$VARIANT_ID" "$directory"; do
    [[ ! -L "$ancestor" ]] || ci_die "Verified cache path contains a symbolic link"
  done
}

write_inputs() {
  mkdir -p "$logs"
  jq -n \
    --arg repository "$repository" \
    --arg workflow "$workflow" \
    --arg run "$run_key" \
    --arg operation "$OPERATION" \
    --arg source_run "${SOURCE_RUN:-}" \
    --arg workflow_revision "$GITHUB_SHA" \
    --arg revision "$BUILD_REVISION" \
    --arg profile "$PROFILE" \
    --arg config "$CONFIG_PATH" \
    --arg config_sha "$PROFILE_CONFIG_SHA256" \
    --arg tools_sha "$TOOLCHAIN_CONFIG_SHA256" \
    --arg macos_family "$MACOS_FAMILY" \
    --arg macos_version "$MACOS_VERSION" \
    --arg macos_build "$MACOS_BUILD" \
    --argjson prerelease "$IMAGE_PRERELEASE" \
    --arg ipsw_url "$IPSW_URL" \
    --argjson ipsw_size "${IPSW_SIZE:-null}" \
    --arg ipsw_sha "$IPSW_SHA256" \
    --arg source_profile "$VANILLA_SOURCE_PROFILE" \
    --arg source_config_sha "$VANILLA_SOURCE_CONFIG_SHA256" \
    --arg source_version "$VANILLA_SOURCE_VERSION" \
    --arg source_build "$VANILLA_SOURCE_BUILD" \
    --arg source_image_digest "$VANILLA_SOURCE_DIGEST" \
    --arg installer_url "$INSTALLER_URL" \
    --argjson installer_size "${INSTALLER_SIZE:-null}" \
    --arg installer_sha "$INSTALLER_SHA256" \
    --arg variant "$VARIANT" \
    --arg variant_id "$VARIANT_ID" \
    --arg xcode "${XCODE_VERSION:-}" \
    --arg xcode_tag "$XCODE_TAG" \
    --argjson update_latest "$UPDATE_LATEST" \
    --arg package "$PACKAGE_REF" \
    --arg latest "$LATEST_REF" \
    --arg tart "$TART_VERSION" \
    --arg packer "$PACKER_VERSION" \
    --arg go "$GO_VERSION" \
    --arg plugin "$PACKER_TART_PLUGIN_VERSION" \
    --arg swift "$SWIFT_VERSION" '
      {
        format: 1,
        repository: $repository,
        workflow: $workflow,
        run_id: $run,
        operation: $operation,
        source_run: $source_run,
        workflow_revision: $workflow_revision,
        revision: $revision,
        profile: $profile,
        config: $config,
        config_sha256: $config_sha,
        toolchain_sha256: $tools_sha,
        macos: {family: $macos_family, version: $macos_version, build: $macos_build},
        prerelease: $prerelease,
        variant: $variant,
        variant_id: $variant_id,
        xcode_version: $xcode,
        xcode_tag: $xcode_tag,
        update_latest: $update_latest,
        package_reference: $package,
        latest_reference: $latest,
        tools: {
          tart: $tart,
          packer: $packer,
          go: $go,
          packer_tart_plugin: $plugin,
          swift: $swift
        },
        source: "",
        source_digest: "",
        xcode_archive_sha256: ""
      }
      | if $source_profile == "" then
          .ipsw = {url: $ipsw_url, size: $ipsw_size, sha256: $ipsw_sha}
        elif $variant == "vanilla" then
          .upgrade = {
            source_profile: $source_profile,
            source_config_sha256: $source_config_sha,
            source_macos: {version: $source_version, build: $source_build},
            source_digest: $source_image_digest,
            installer: {url: $installer_url, size: $installer_size, sha256: $installer_sha}
          }
        else
          .
        end
    ' > "$logs/inputs.json"
}

set_input_sources() {
  local source=$1
  local source_digest=$2
  local xcode_sha=$3
  local temporary="$logs/inputs.json.tmp"
  jq \
    --arg source "$source" \
    --arg source_digest "$source_digest" \
    --arg xcode_sha "$xcode_sha" \
    '.source = $source | .source_digest = $source_digest | .xcode_archive_sha256 = $xcode_sha' \
    "$logs/inputs.json" > "$temporary"
  mv "$temporary" "$logs/inputs.json"
}

tool_version() {
  .build/tools/image-artifact run --timeout 20 -- "$@" 2>&1 | grep -Eo '[0-9]+([.][0-9]+){1,2}' | sed -n '1p'
}

check_tools() {
  local available
  local minimum_kib=$((100 * 1024 * 1024))
  local plugin_versions
  local swift_version
  for command in bash go jq lsof make oras packer shasum swift tart; do
    command -v "$command" >/dev/null || ci_die "Missing required command: $command"
  done
  [[ $(uname -m) == arm64 ]] || ci_die "The image runner must use Apple silicon"
  [[ $(sw_vers -productVersion | cut -d. -f1) -ge "$MINIMUM_HOST_MAJOR" ]] || ci_die "The runner macOS version is too old"
  make artifact-helper
  [[ $(tool_version tart --version) == "$TART_VERSION" ]] || ci_die "Unexpected Tart version"
  [[ $(tool_version packer version) == "$PACKER_VERSION" ]] || ci_die "Unexpected Packer version"
  [[ $(tool_version go version) == "$GO_VERSION" ]] || ci_die "Unexpected Go version"
  swift_version=$(.build/tools/image-artifact run --timeout 20 -- xcrun swift --version |
    sed -n '1s/.*Swift version \([0-9][0-9.]*\).*/\1/p')
  [[ "$swift_version" == "$SWIFT_VERSION" ]] || ci_die "Unexpected Swift version: $swift_version"
  [[ $(tool_version oras version) == 1.3.0 ]] || ci_die "Unexpected ORAS version"
  plugin_versions=$(.build/tools/image-artifact run --timeout 20 -- packer plugins installed 2>&1 |
    grep -F 'github.com/cirruslabs/tart' | grep -Eo 'v[0-9]+([.][0-9]+){2}' | LC_ALL=C sort -u || true)
  [[ "$plugin_versions" == "v$PACKER_TART_PLUGIN_VERSION" ]] || ci_die "Unexpected Tart Packer plugin version"
  if [[ "$OPERATION" == upload-only || "$OPERATION" == recover-upload ]]; then
    local metadata="$task_root/recovery/bundle.json"
    local result="$task_root/recovery/result.json"
    local bundle_kib
    [[ -f "$metadata" && ! -L "$metadata" ]] || ci_die "Saved VM metadata is missing"
    [[ -f "$result" && ! -L "$result" ]] || ci_die "Saved image result is missing"
    [[ $(ci_sha256 "$metadata") == "${BUNDLE_METADATA_SHA256:?}" ]] || ci_die "Saved VM metadata changed"
    [[ $(ci_sha256 "$result") == "${SOURCE_RESULT_SHA256:?}" ]] || ci_die "Saved image result changed"
    case $(jq -er .stage "$result") in
      built)
        if [[ "$OPERATION" == upload-only ]]; then
          bundle_kib=$(jq -er '([.files[].size] | add) / 1024 | ceil' "$metadata")
          [[ "$bundle_kib" =~ ^[1-9][0-9]*$ ]] || ci_die "Invalid saved VM size"
          minimum_kib=$((bundle_kib + (bundle_kib + 19) / 20 + 2 * 1024 * 1024))
        elif [[ "$VARIANT" == xcode ]]; then
          minimum_kib=$((250 * 1024 * 1024))
        fi
        ;;
      prepared|verified)
        minimum_kib=$((2 * 1024 * 1024))
        if [[ "$OPERATION" == recover-upload ]]; then
          local directory download_kib import_kib
          directory=$(verified_directory "$BUILD_RUN")
          require_verified_path "$directory"
          [[ -d "$directory/vm" && ! -L "$directory/vm" &&
             -z $(find "$directory/vm" -type l -print -quit) ]] || ci_die "Invalid saved VM directory"
          download_kib=$(jq -er '.blob_bytes | select(type == "number" and . > 0) | . / 1024 | ceil' "$result")
          import_kib=$(du -sk "$directory/vm" | awk '{print $1}')
          [[ "$download_kib" =~ ^[1-9][0-9]*$ && "$import_kib" =~ ^[1-9][0-9]*$ ]] || ci_die "Invalid publication size"
          minimum_kib=$download_kib
          (( import_kib <= minimum_kib )) || minimum_kib=$import_kib
          minimum_kib=$((minimum_kib + 20 * 1024 * 1024))
        fi
        ;;
      *) ci_die "Recovery requires a built, prepared, or verified image" ;;
    esac
  elif [[ "$VARIANT" == xcode ]]; then
    minimum_kib=$((250 * 1024 * 1024))
  fi
  parent_cache_init
  parent_cache_credit_kib=0
  parent_cache_keep=
  if [[ ( "$OPERATION" == build || "$OPERATION" == publish ) &&
        ( "$VARIANT" != vanilla || -n "$VANILLA_SOURCE_PROFILE" ) ]]; then
    prepare_parent_source
    minimum_kib=$((minimum_kib - parent_cache_credit_kib))
  fi
  if [[ ( "$OPERATION" == build || "$OPERATION" == publish ) &&
        "$VARIANT" == vanilla && -n "$VANILLA_SOURCE_PROFILE" ]]; then
    minimum_kib=$((minimum_kib + (INSTALLER_SIZE + 1023) / 1024))
  fi
  parent_cache_prune "$minimum_kib" "$parent_cache_keep"
  available=$(df -Pk "$RUNNER_TEMP" | awk 'END {print $4}')
  [[ "$available" =~ ^[0-9]+$ && "$available" -ge "$minimum_kib" ]] ||
    ci_die "The image runner requires $minimum_kib KiB free; $available KiB is available"
  [[ $(git remote get-url origin) == "$repository_url" ]] || ci_die "Unexpected source origin"
  [[ -z $(git status --porcelain --untracked-files=normal) ]] || ci_die "The checked-out source is not clean"
  [[ $(git rev-parse HEAD) == "$GITHUB_SHA" ]] || ci_die "The checkout revision changed"
  .build/tools/image-artifact run --timeout 600 -- xcrun swift build --disable-keychain --skip-update \
    --disable-automatic-resolution --disable-dependency-cache --cache-path "$task_root/swift-cache" \
    -c release --product macos-image
  [[ -x .build/tools/image-artifact ]] || ci_die "The artifact helper was not built"
  .build/tools/image-artifact run --timeout 60 -- ./scripts/image doctor
}

inspect_layout() {
  local directory=$1
  local output=$2
  .build/tools/image-artifact inspect --layout "$directory" > "$output"
}

require_layout() {
  local metadata=$1
  local expected_variant=$2
  local expected_xcode=${3:-}
  local expected_revision=${4:-}
  local expected_source=${5:-}
  local expected_version=${6:-$MACOS_VERSION}
  local expected_build=${7:-$MACOS_BUILD}
  jq -e \
    --arg revision "$expected_revision" \
    --arg macos_version "$expected_version" \
    --arg macos_build "$expected_build" \
    --arg variant "$expected_variant" \
    --arg xcode "$expected_xcode" \
    --arg source "$expected_source" '
      (.manifest_digest | test("^sha256:[0-9a-f]{64}$")) and
      (.manifest_size | type == "number" and . > 0) and
      (.blob_bytes | type == "number" and . > 0) and
      (.revision | test("^[0-9a-f]{40}$")) and
      ($revision == "" or .revision == $revision) and
      .macos_version == $macos_version and .macos_build == $macos_build and
      .variant == $variant and ((.xcode_version // "") == $xcode) and
      (.source | type == "string" and length > 0) and
      ($source == "" or .source == $source)
    ' "$metadata" >/dev/null || ci_die "OCI metadata does not match the requested image"
}

stop_vm() {
  local vm=$1
  local state
  state=$(.build/tools/image-artifact run --timeout 20 -- tart get "$vm" | awk 'NR == 2 {print $NF}')
  if [[ "$state" == running ]]; then
    .build/tools/image-artifact run --timeout 30 -- tart stop "$vm"
    state=$(.build/tools/image-artifact run --timeout 20 -- tart get "$vm" | awk 'NR == 2 {print $NF}')
  fi
  [[ -n "$state" && "$state" != running ]] || ci_die "VM did not stop: $vm"
}

require_closed_bundle() {
  local bundle=$1
  local disk
  local output
  local status
  while IFS= read -r disk; do
    status=0
    output=$(.build/tools/image-artifact run --timeout 20 -- lsof -t -- "$disk" 2>&1) || status=$?
    [[ "$status" == 1 && -z "$output" ]] || ci_die "Could not confirm that a VM disk is closed: $disk"
  done < <(find "$bundle" -type f -name disk.img -print)
}

bundle_files_json() {
  local bundle=$1
  local files='[]'
  local relative
  local size
  local digest
  [[ $(find "$bundle" -mindepth 1 -maxdepth 1 -print | sed 's#.*/##' | LC_ALL=C sort | tr '\n' ' ') == "config.json disk.img nvram.bin " ]] ||
    ci_die "VM bundle must contain exactly config.json, disk.img and nvram.bin"
  for relative in config.json disk.img nvram.bin; do
    [[ -f "$bundle/$relative" && ! -L "$bundle/$relative" ]] || ci_die "Invalid VM bundle file: $relative"
    size=$(stat -f %z "$bundle/$relative")
    digest=$(ci_sha256 "$bundle/$relative")
    files=$(jq -cn --argjson files "$files" --arg path "$relative" --argjson size "$size" --arg digest "$digest" \
      '$files + [{path: $path, size: $size, sha256: $digest}]')
  done
  printf '%s\n' "$files"
}

save_verified_bundle() {
  local build_run=$1
  local bundle="$tart_home/vms/$vm_name"
  local destination
  local temporary
  local files
  destination=$(verified_directory "$build_run")
  temporary="$destination.incomplete-$run_key"
  [[ -d "$bundle" && ! -L "$bundle" ]] || ci_die "Built VM bundle is missing"
  require_verified_path "$destination"
  require_verified_path "$temporary"
  [[ ! -e "$destination" && ! -L "$destination" && ! -e "$temporary" && ! -L "$temporary" ]] ||
    ci_die "A verified bundle already exists for $build_run"
  stop_vm "$vm_name"
  require_closed_bundle "$bundle"
  umask 077
  if ! (
    mkdir -p "$temporary/vm" || exit 1
    for file in config.json disk.img nvram.bin; do
      /bin/cp -c "$bundle/$file" "$temporary/vm/$file" || exit 1
    done
    files=$(bundle_files_json "$temporary/vm") || exit 1
    jq -n \
      --arg repository "$repository" \
      --arg build_run "$build_run" \
      --arg revision "$BUILD_REVISION" \
      --arg profile "$PROFILE" \
      --arg variant "$VARIANT_ID" \
      --arg config_sha "$PROFILE_CONFIG_SHA256" \
      --arg tools_sha "$TOOLCHAIN_CONFIG_SHA256" \
      --argjson files "$files" '
        {
          format: 1,
          repository: $repository,
          build_run: $build_run,
          revision: $revision,
          profile: $profile,
          variant: $variant,
          config_sha256: $config_sha,
          toolchain_sha256: $tools_sha,
          files: $files
        }
      ' > "$temporary/bundle.json" || exit 1
  ); then
    rm -rf -- "$temporary"
    return 1
  fi
  if ! mv "$temporary" "$destination"; then
    rm -rf -- "$temporary"
    return 1
  fi
  if ! cp "$destination/bundle.json" "$logs/bundle.json"; then
    verify_bundle "$destination"
    rm -rf -- "$destination"
    return 1
  fi
}

write_built_result() {
  local build_run=$1
  local recovery_digest=${2:-}
  local source
  source=$(jq -er .source "$logs/inputs.json")
  jq -n \
    --arg repository "$repository" \
    --arg run "$run_key" \
    --arg build_run "$build_run" \
    --arg revision "$BUILD_REVISION" \
    --arg profile "$PROFILE" \
    --arg variant "$VARIANT" \
    --arg variant_id "$VARIANT_ID" \
    --arg xcode "${XCODE_VERSION:-}" \
    --arg xcode_tag "$XCODE_TAG" \
    --argjson update_latest "$UPDATE_LATEST" \
    --arg macos_version "$MACOS_VERSION" \
    --arg macos_build "$MACOS_BUILD" \
    --arg package "$PACKAGE_REF" \
    --arg latest "$LATEST_REF" \
    --arg source "$source" \
    --arg repository_url "$repository_url" \
    --arg recovery_digest "$recovery_digest" '
      {
        format: 1,
        result: "passed",
        stage: "built",
        repository: $repository,
        run_id: $run,
        build_run: $build_run,
        revision: $revision,
        profile: $profile,
        variant: $variant,
        variant_id: $variant_id,
        xcode_version: $xcode,
        xcode_tag: $xcode_tag,
        update_latest: $update_latest,
        macos_version: $macos_version,
        macos_build: $macos_build,
        package_reference: $package,
        latest_reference: $latest,
        build_source: $source,
        oci_source: $repository_url,
        recovery_expected_digest: $recovery_digest
      }
    ' > "$logs/result.json"
}

verify_bundle() {
  local directory=$1
  local metadata="$directory/bundle.json"
  local path
  local actual_count
  [[ -f "$metadata" && ! -L "$metadata" && -d "$directory/vm" && ! -L "$directory/vm" ]] || ci_die "Saved VM bundle is incomplete"
  jq -e \
    --arg repository "$repository" \
    --arg build_run "$BUILD_RUN" \
    --arg revision "$BUILD_REVISION" \
    --arg profile "$PROFILE" \
    --arg variant "$VARIANT_ID" \
    --arg config_sha "$PROFILE_CONFIG_SHA256" \
    --arg tools_sha "$TOOLCHAIN_CONFIG_SHA256" '
      .format == 1 and .repository == $repository and .build_run == $build_run and
      .revision == $revision and .profile == $profile and .variant == $variant and
      .config_sha256 == $config_sha and .toolchain_sha256 == $tools_sha and
      (.files | type == "array" and length > 0) and
      ([.files[].path] | sort) == ["config.json", "disk.img", "nvram.bin"] and
      all(.files[];
        (.path | test("^[A-Za-z0-9._/-]+$")) and
        (.size | type == "number" and . >= 0) and
        (.sha256 | test("^[0-9a-f]{64}$")))
    ' "$metadata" >/dev/null || ci_die "Saved VM metadata does not match this request"
  [[ $(find "$directory/vm" -mindepth 1 -maxdepth 1 -print | sed 's#.*/##' | LC_ALL=C sort | tr '\n' ' ') == "config.json disk.img nvram.bin " ]] ||
    ci_die "Saved VM bundle has unexpected entries"
  actual_count=$(find "$directory/vm" -type f | wc -l | tr -d ' ')
  [[ "$actual_count" == 3 && $(jq '.files | length' "$metadata") == 3 ]] || ci_die "Saved VM file list is incomplete"
  while IFS= read -r path; do
    local expected_size
    local expected_digest
    [[ -f "$directory/vm/$path" && ! -L "$directory/vm/$path" ]] || ci_die "Saved VM file is missing: $path"
    expected_size=$(jq -er --arg path "$path" '.files[] | select(.path == $path) | .size' "$metadata")
    expected_digest=$(jq -er --arg path "$path" '.files[] | select(.path == $path) | .sha256' "$metadata")
    [[ $(stat -f %z "$directory/vm/$path") == "$expected_size" ]] || ci_die "Saved VM size mismatch: $path"
    [[ $(ci_sha256 "$directory/vm/$path") == "$expected_digest" ]] || ci_die "Saved VM hash mismatch: $path"
  done < <(jq -r '.files[].path' "$metadata")
}

save_publication_layout() {
  local directory
  local saved="$layout"
  local temporary
  directory=$(verified_directory "$BUILD_RUN")
  temporary="$directory/layout.incomplete-$run_key"
  require_verified_path "$directory"
  verify_bundle "$directory"
  [[ -z $(find "$saved" -type l -print -quit) ]] || ci_die "Prepared OCI layout contains a symbolic link"
  [[ ! -e "$directory/layout" && ! -L "$directory/layout" && ! -e "$directory/layout.json" && ! -L "$directory/layout.json" &&
     ! -e "$temporary" && ! -L "$temporary" ]] || ci_die "A prepared layout already exists for $BUILD_RUN"
  if ! (
    /bin/cp -cR "$saved" "$temporary" || exit 1
    [[ -z $(find "$temporary" -type l -print -quit) ]] || exit 1
    inspect_layout "$temporary" "$directory/layout.json.tmp" || exit 1
    mv "$temporary" "$directory/layout" || exit 1
    mv "$directory/layout.json.tmp" "$directory/layout.json" || exit 1
  ); then
    for path in "$temporary" "$directory/layout.json.tmp" "$directory/layout"; do
      if [[ -e "$path" || -L "$path" ]]; then
        [[ ! -L "$path" ]] || ci_die "Invalid incomplete layout cache"
        rm -rf -- "$path"
      fi
    done
    return 1
  fi
  if [[ $(jq -er .manifest_digest "$directory/layout.json") != "$(jq -er .manifest_digest "$logs/inspect.json")" ]]; then
    rm -rf -- "$directory/layout"
    rm -f -- "$directory/layout.json"
    ci_die "Saved layout digest changed"
  fi
}

restore_publication_layout() {
  local directory
  directory=$(verified_directory "$BUILD_RUN")
  require_verified_path "$directory"
  verify_bundle "$directory"
  [[ -d "$directory/layout" && ! -L "$directory/layout" && -f "$directory/layout.json" && ! -L "$directory/layout.json" ]] ||
    ci_die "The exact prepared OCI layout was not retained"
  [[ -z $(find "$directory/layout" -type l -print -quit) ]] || ci_die "Saved OCI layout contains a symbolic link"
  inspect_layout "$directory/layout" "$task_root/saved-layout.json"
  [[ $(ci_sha256 "$directory/layout.json") == "$(ci_sha256 "$task_root/saved-layout.json")" ]] || ci_die "Saved layout metadata changed"
  [[ $(jq -er .manifest_digest "$task_root/saved-layout.json") == "$1" ]] || ci_die "Saved layout digest differs from the authorized result"
  mkdir -p "$task_root/publication"
  /bin/cp -cR "$directory/layout" "$layout"
}

remove_verified_bundle() {
  local directory
  directory=$(verified_directory "$BUILD_RUN")
  require_verified_path "$directory"
  verify_bundle "$directory"
  [[ "$directory" == "$verified_root/$PROFILE/$VARIANT_ID/$BUILD_RUN" ]] || ci_die "Invalid verified bundle path"
  rm -rf -- "$directory"
}

initialize() {
  [[ -d "$task_root" && ! -L "$task_root" ]] || ci_die "Bootstrap task directory is missing"
  [[ "$root_dir" == "$task_root/source" ]] || ci_die "Source checkout is outside the private task"
  [[ -f "$task_root/.bootstrap" && ! -L "$task_root/.bootstrap" ]] || ci_die "Bootstrap marker is missing"
  jq -e --arg repository "$repository" --arg run "$run_key" --arg revision "$GITHUB_SHA" \
    '.format == 1 and .repository == $repository and .run == $run and .revision == $revision' \
    "$task_root/.bootstrap" >/dev/null || ci_die "Bootstrap marker does not match this run"
  [[ ! -e "$marker" ]] || ci_die "Task is already initialized"
  mkdir -p "$tart_home/vms" "$logs"
  expected_marker > "$marker"
  write_inputs
}

check_runner() {
  require_task
  check_tools
}

build_image() {
  require_task
  local source=
  local source_digest=
  local xcode_sha=
  local source_layout="$task_root/parent-image/layout"
  local source_metadata="$task_root/parent-image.json"

  if [[ "$VARIANT" == xcode ]]; then
    local archive="${XCODE_CACHE:-$HOME/XcodesCache}/Xcode_$XCODE_VERSION.xip"
    local silicon_archive="${XCODE_CACHE:-$HOME/XcodesCache}/Xcode_${XCODE_VERSION}_Apple_silicon.xip"
    if [[ -e "$silicon_archive" || -L "$silicon_archive" ]]; then
      archive=$silicon_archive
    fi
    [[ -f "$archive" && ! -L "$archive" && -r "$archive" && -s "$archive" ]] ||
      ci_die "A readable, nonempty Xcode archive is required: $archive"
    xcode_sha=$(ci_sha256 "$archive")
  fi

  if [[ "$VARIANT" == vanilla && -z "$VANILLA_SOURCE_PROFILE" ]]; then
    source=$IPSW_URL
    source_digest="sha256:$IPSW_SHA256"
    ./scripts/image build vanilla "" "$vm_name"
  else
    mkdir -p "$task_root/parent-image"
    restore_parent_source "$source_layout" "$source_metadata"
    source_digest=$(jq -er .manifest_digest "$source_metadata")
    source=$(jq -er .reference "$task_root/parent-source.json")
    .build/tools/image-artifact import --layout "$source_layout" --vm "$source_vm"
    rm -rf -- "$source_layout"
    case "$VARIANT" in
      vanilla) VANILLA_SOURCE_VM="$source_vm" ./scripts/image build vanilla "" "$vm_name" ;;
      base) ./scripts/image build base "$source_vm" "$vm_name" ;;
      xcode) ./scripts/image build xcode "$XCODE_VERSION" "$source_vm" "$vm_name" ;;
    esac
  fi
  ./scripts/image test "$vm_name" "$VARIANT"
  set_input_sources "$source" "$source_digest" "$xcode_sha"
  save_verified_bundle "$run_key"
  write_built_result "$run_key"
}

restore_image() {
  require_task
  local source_inputs="$SOURCE_ARTIFACT_DIR/inputs.json"
  local source_result="$SOURCE_ARTIFACT_DIR/result.json"
  local directory
  local recovery_digest
  [[ $(ci_sha256 "$source_inputs") == "$SOURCE_INPUTS_SHA256" ]] || ci_die "Recovery inputs changed after authorization"
  [[ $(ci_sha256 "$source_result") == "$SOURCE_RESULT_SHA256" ]] || ci_die "Recovery result changed after authorization"
  [[ $(jq -er .build_run "$source_result") == "$BUILD_RUN" ]] || ci_die "Recovery build run changed after authorization"
  [[ $(jq -er .revision "$source_result") == "$BUILD_REVISION" ]] || ci_die "Recovery revision changed after authorization"
  [[ $(ci_sha256 "$SOURCE_ARTIFACT_DIR/bundle.json") == "$BUNDLE_METADATA_SHA256" ]] || ci_die "Recovery bundle metadata changed after authorization"
  directory=$(verified_directory "$BUILD_RUN")
  require_verified_path "$directory"
  verify_bundle "$directory"
  [[ $(ci_sha256 "$directory/bundle.json") == "$BUNDLE_METADATA_SHA256" ]] || ci_die "Local VM metadata does not match the original build artifact"
  /bin/cp -cR "$directory/vm" "$tart_home/vms/$vm_name"
  set_input_sources \
    "$(jq -er .source "$source_inputs")" \
    "$(jq -er .source_digest "$source_inputs")" \
    "$(jq -er .xcode_archive_sha256 "$source_inputs")"
  cp "$SOURCE_ARTIFACT_DIR/bundle.json" "$logs/bundle.json"
  recovery_digest=$(jq -er '.manifest_digest // .recovery_expected_digest // ""' "$source_result")
  if [[ -z "$recovery_digest" ]]; then
    [[ "$SOURCE_RUN" =~ ^[1-9][0-9]*-[1-9][0-9]*$ ]] || ci_die "Invalid recovery source run"
    for path in \
      "$directory/layout.incomplete-$BUILD_RUN" \
      "$directory/layout.incomplete-$SOURCE_RUN" \
      "$directory/layout.incomplete-$run_key" \
      "$directory/layout.json.tmp" \
      "$directory/layout" \
      "$directory/layout.json"; do
      if [[ -e "$path" || -L "$path" ]]; then
        [[ ! -L "$path" ]] || ci_die "Invalid unanchored layout cache"
        rm -rf -- "$path"
      fi
    done
  fi
  write_built_result "$BUILD_RUN" "$recovery_digest"
}

prepare_publication() {
  require_task
  jq -e '.result == "passed" and .stage == "built"' "$logs/result.json" >/dev/null || ci_die "A verified build is required"
  local source
  local inspect="$logs/inspect.json"
  local digest
  local hash
  local expected
  source=$(jq -er .oci_source "$logs/result.json")
  expected=$(jq -er .recovery_expected_digest "$logs/result.json")
  if [[ -n "$expected" ]]; then
    restore_publication_layout "$expected"
  else
    mkdir -p "$task_root/publication"
    IMAGE_REVISION="$BUILD_REVISION" IMAGE_SOURCE="$source" ./scripts/registry prepare "$vm_name" "$PACKAGE_REF" "$layout"
  fi
  inspect_layout "$layout" "$inspect"
  require_layout "$inspect" "$VARIANT" "${XCODE_VERSION:-}" "$BUILD_REVISION" "$source"
  digest=$(jq -er .manifest_digest "$inspect")
  [[ -z "$expected" || "$digest" == "$expected" ]] || ci_die "Recovered export digest differs from the original export"
  hash=${digest#sha256:}
  cp "$layout/blobs/sha256/$hash" "$logs/oci-manifest.json"
  if [[ -z "$expected" ]]; then
    save_publication_layout
  fi
  local temporary="$logs/result.json.tmp"
  jq --arg digest "$digest" --argjson size "$(jq -er .manifest_size "$inspect")" --argjson bytes "$(jq -er .blob_bytes "$inspect")" \
    '.stage = "prepared" | .manifest_digest = $digest | .manifest_size = $size | .blob_bytes = $bytes' \
    "$logs/result.json" > "$temporary"
  mv "$temporary" "$logs/result.json"
  jq -n \
    --arg macos_family "$MACOS_FAMILY" \
    --arg macos_version "$MACOS_VERSION" \
    --arg macos_build "$MACOS_BUILD" \
    --arg variant "$VARIANT" \
    --arg variant_id "$VARIANT_ID" \
    --arg xcode "${XCODE_VERSION:-}" \
    --arg xcode_tag "$XCODE_TAG" \
    --argjson update_latest "$UPDATE_LATEST" \
    --arg reference "${PACKAGE_REF%:*}@$digest" '
      {
        format: 1,
        macos: {family: $macos_family, version: $macos_version, build: $macos_build, architecture: "arm64"},
        variant: $variant,
        variant_id: $variant_id,
        xcode_version: $xcode,
        xcode_tag: $xcode_tag,
        update_latest: $update_latest,
        source: {type: "prebuilt", reference: $reference}
      }
    ' > "$logs/image-spec.json"
}

upload_publication() {
  require_task
  local digest
  local digest_ref
  local state
  digest=$(jq -er 'select(.stage == "prepared") | .manifest_digest' "$logs/result.json")
  digest_ref="${PACKAGE_REF%:*}@$digest"
  unset GH_TOKEN
  state=$(./scripts/registry check "$digest_ref" "$digest")
  case "$state" in
    absent)
      [[ $(./scripts/registry upload "$layout" "$PACKAGE_REF") == "$digest" ]] || ci_die "Registry upload returned the wrong digest"
      ;;
    present) ;;
    *) ci_die "Unexpected registry state: $state" ;;
  esac
  [[ $(./scripts/registry check "$digest_ref" "$digest") == present ]] || ci_die "Uploaded digest was not found"
}

require_publication_space() {
  [[ "$1" =~ ^[1-9][0-9]*$ ]] || ci_die "Invalid publication size"
  local minimum_kib=$(($1 + 20 * 1024 * 1024)) available
  parent_cache_init
  parent_cache_prune "$minimum_kib"
  available=$(df -Pk "$RUNNER_TEMP" | awk 'END {print $4}')
  [[ "$available" =~ ^[0-9]+$ && "$available" -ge "$minimum_kib" ]] ||
    ci_die "Publication requires $minimum_kib KiB free; $available KiB is available"
}

download_cache_directory() {
  local directory
  directory=$(verified_directory "$BUILD_RUN")
  require_verified_path "$directory"
  printf '%s/anonymous-download\n' "$directory"
}

download_manifest() {
  local directory digest
  directory=$(verified_directory "$BUILD_RUN")
  digest=$(jq -er '.manifests[0].digest' "$directory/layout/index.json")
  [[ "$digest" =~ ^sha256:[0-9a-f]{64}$ ]] || ci_die 'Invalid saved manifest digest'
  printf '%s/layout/blobs/sha256/%s\n' "$directory" "${digest#sha256:}"
}

download_cache_bytes() {
  local cache manifest hash size file total=0 count=0 actual
  cache=$(download_cache_directory)
  [[ -e "$cache" || -L "$cache" ]] || { printf '0\n'; return; }
  [[ -d "$cache/blobs/sha256" && ! -L "$cache" && ! -L "$cache/blobs" &&
     ! -L "$cache/blobs/sha256" && -z $(find "$cache" -type l -print -quit) ]] ||
    ci_die 'Invalid anonymous download cache'
  manifest=$(download_manifest)
  while read -r hash size; do
    [[ "$hash" =~ ^[0-9a-f]{64}$ && "$size" =~ ^[1-9][0-9]*$ ]] || ci_die 'Invalid saved blob descriptor'
    file="$cache/blobs/sha256/$hash"
    [[ -e "$file" || -L "$file" ]] || continue
    [[ -f "$file" && ! -L "$file" && $(stat -f %z "$file") == "$size" &&
       $(ci_sha256 "$file") == "$hash" ]] || ci_die "Invalid cached blob: $hash"
    total=$((total + size))
    count=$((count + 1))
  done < <(jq -r '[.config, .layers[]] | unique_by(.digest)[] | "\(.digest | ltrimstr("sha256:")) \(.size)"' "$manifest")
  actual=$(find "$cache/blobs/sha256" -mindepth 1 -maxdepth 1 | wc -l | tr -d ' ')
  [[ "$actual" == "$count" ]] || ci_die 'Anonymous download cache contains unexpected files'
  printf '%s\n' "$total"
}

save_download_cache() {
  local downloaded="$task_root/downloaded/layout/blobs/sha256"
  local cache manifest hash size source destination temporary
  [[ -d "$downloaded" && ! -L "$downloaded" ]] || return 0
  cache=$(download_cache_directory)
  manifest=$(download_manifest)
  if [[ -e "$cache" || -L "$cache" ]]; then
    download_cache_bytes >/dev/null
  else
    (umask 077; mkdir -p "$cache/blobs/sha256")
  fi
  while read -r hash size; do
    [[ "$hash" =~ ^[0-9a-f]{64}$ && "$size" =~ ^[1-9][0-9]*$ ]] || ci_die 'Invalid saved blob descriptor'
    source="$downloaded/$hash"
    destination="$cache/blobs/sha256/$hash"
    [[ -f "$source" && ! -L "$source" && $(stat -f %z "$source") == "$size" ]] || continue
    [[ -e "$destination" || -L "$destination" ]] && continue
    temporary="$cache/blobs/sha256/.$hash-$run_key"
    [[ ! -e "$temporary" && ! -L "$temporary" ]] || ci_die 'Anonymous download cache staging file already exists'
    /bin/cp -c "$source" "$temporary"
    mv "$temporary" "$destination"
  done < <(jq -r '[.config, .layers[]] | unique_by(.digest)[] | "\(.digest | ltrimstr("sha256:")) \(.size)"' "$manifest")
  printf 'Saved completed anonymous download blobs\n'
}

retain_downloaded_layout() {
  local downloaded=$1 digest=$2 directory hash blob
  local temporary="$task_root/publication/downloaded-blob"
  local metadata="$task_root/retained-layout.json"
  directory=$(verified_directory "$BUILD_RUN")
  require_verified_path "$directory"
  [[ -d "$directory/layout" && ! -L "$directory/layout" &&
     -f "$directory/layout.json" && ! -L "$directory/layout.json" &&
     -z $(find "$directory/layout" -type l -print -quit) ]] || ci_die "Invalid saved publication layout"
  [[ -d "$downloaded" && ! -L "$downloaded" &&
     -z $(find "$downloaded" -type l -print -quit) ]] || ci_die "Invalid downloaded publication layout"
  [[ $(stat -f '%d' "$downloaded") == "$(stat -f '%d' "$directory/layout")" ]] ||
    ci_die "Publication layouts must be on the same filesystem"
  [[ ! -e "$temporary" && ! -L "$temporary" ]] || ci_die "Publication clone destination already exists"
  inspect_layout "$directory/layout" "$metadata"
  [[ $(ci_sha256 "$metadata") == "$(ci_sha256 "$directory/layout.json")" &&
     $(jq -er .manifest_digest "$metadata") == "$digest" ]] || ci_die "Saved publication layout changed"
  for blob in "$directory/layout/blobs/sha256/"*; do
    hash=${blob##*/}
    [[ "$hash" =~ ^[0-9a-f]{64}$ && -f "$blob" && ! -L "$blob" &&
       -f "$downloaded/blobs/sha256/$hash" && ! -L "$downloaded/blobs/sha256/$hash" ]] ||
      ci_die "Invalid publication blob: $hash"
    /bin/cp -c "$downloaded/blobs/sha256/$hash" "$temporary"
    [[ $(ci_sha256 "$temporary") == "$hash" ]] || ci_die "Downloaded publication blob changed: $hash"
    mv -f "$temporary" "$blob"
  done
  inspect_layout "$directory/layout" "$metadata"
  [[ $(ci_sha256 "$metadata") == "$(ci_sha256 "$directory/layout.json")" ]] ||
    ci_die "Retained publication layout changed"
  rm -rf -- "$layout"
  printf 'Retained the verified anonymous download with APFS clones\n'
}

verify_publication() {
  require_task
  local digest cached_bytes remaining_bytes
  local downloaded="$task_root/downloaded/layout"
  local inspect="$task_root/downloaded.json"
  local source
  local digest_ref
  digest=$(jq -er 'select(.stage == "prepared") | .manifest_digest' "$logs/result.json")
  digest_ref="${PACKAGE_REF%:*}@$digest"
  source=$(jq -er .oci_source "$logs/result.json")
  unset GH_TOKEN TART_REGISTRY_HOSTNAME TART_REGISTRY_USERNAME TART_REGISTRY_PASSWORD
  [[ $(./scripts/registry check "$digest_ref" "$digest") == present ]] || ci_die "The uploaded digest is not public"
  cached_bytes=$(download_cache_bytes)
  remaining_bytes=$(jq -er --argjson cached "$cached_bytes" '((if .blob_bytes > $cached then .blob_bytes - $cached else 0 end) / 1024) | ceil' "$logs/result.json")
  (( remaining_bytes > 0 )) || remaining_bytes=1
  require_publication_space "$remaining_bytes"
  mkdir -p "$task_root/downloaded"
  if (( cached_bytes > 0 )); then
    /bin/cp -cR "$(download_cache_directory)" "$downloaded"
    printf 'Resuming anonymous download with %s cached bytes\n' "$cached_bytes"
    ./scripts/registry download "$digest_ref" "$downloaded" --resume
  else
    ./scripts/registry download "$digest_ref" "$downloaded"
  fi
  inspect_layout "$downloaded" "$inspect"
  require_layout "$inspect" "$VARIANT" "${XCODE_VERSION:-}" "$BUILD_REVISION" "$source"
  [[ $(jq -er .manifest_digest "$inspect") == "$digest" ]] || ci_die "Downloaded manifest digest changed"
  retain_downloaded_layout "$downloaded" "$digest"
  require_publication_space "$(du -sk "$(verified_directory "$BUILD_RUN")/vm" | awk '{print $1}')"
  .build/tools/image-artifact import --layout "$downloaded" --vm "$published_vm"
  ./scripts/image test "$published_vm" "$VARIANT"
  jq -n \
    --arg run "$run_key" \
    --arg build_run "$BUILD_RUN" \
    --arg revision "$BUILD_REVISION" \
    --arg digest_reference "$digest_ref" \
    --arg tag_reference "$PACKAGE_REF" \
    --arg latest_reference "$LATEST_REF" \
    --arg digest "$digest" '
      {
        format: 1,
        publication_run: $run,
        build_run: $build_run,
        revision: $revision,
        digest_reference: $digest_reference,
        tag_reference: $tag_reference,
        latest_reference: $latest_reference,
        digest: $digest,
        anonymous_download: "passed",
        import: "passed",
        guest_test: "passed",
        tag_promotion: "pending",
        latest_promotion: "pending"
      }
    ' > "$logs/publication.json"
  local temporary="$logs/result.json.tmp"
  jq '.stage = "verified"' "$logs/result.json" > "$temporary"
  mv "$temporary" "$logs/result.json"
}

promote_publication() {
  require_task
  local digest
  digest=$(jq -er 'select(.stage == "verified") | .manifest_digest' "$logs/result.json")
  ./scripts/registry promote "$PACKAGE_REF" "$digest"
  if [[ "$VARIANT" == xcode && "$IMAGE_PRERELEASE" == false && "$XCODE_PRERELEASE" == false ]]; then
    ./scripts/registry promote-xcode-alias "${PACKAGE_REF%:*}:$XCODE_TAG" "$digest" > "$logs/xcode-alias.json"
  fi
  if [[ -n "$LATEST_REF" ]]; then
    ./scripts/registry promote "$LATEST_REF" "$digest"
  fi
}

complete_publication() {
  require_task
  local digest
  local latest_status=skipped
  local xcode_alias=null
  local temporary
  digest=$(jq -er 'select(.stage == "verified") | .manifest_digest' "$logs/result.json")
  unset GH_TOKEN TART_REGISTRY_HOSTNAME TART_REGISTRY_USERNAME TART_REGISTRY_PASSWORD
  [[ $(./scripts/registry check "$PACKAGE_REF" "$digest") == present ]] || ci_die "Published tag does not match the verified digest"
  if [[ "$VARIANT" == xcode && "$IMAGE_PRERELEASE" == false && "$XCODE_PRERELEASE" == false ]]; then
    xcode_alias=$(jq -ce --arg reference "${PACKAGE_REF%:*}:$XCODE_TAG" --arg digest "$digest" '
      select(.reference == $reference and (.digest | test("^sha256:[0-9a-f]{64}$")) and
        ((.status == "passed" and .digest == $digest) or .status == "retained"))
    ' "$logs/xcode-alias.json") || ci_die "Invalid Xcode alias result"
    [[ $(./scripts/registry check "${PACKAGE_REF%:*}:$XCODE_TAG" "$(jq -er .digest <<< "$xcode_alias")") == present ]] ||
      ci_die "Xcode alias does not match its publication result"
  fi
  if [[ -n "$LATEST_REF" ]]; then
    [[ $(./scripts/registry check "$LATEST_REF" "$digest") == present ]] || ci_die "Latest tag does not match the verified digest"
    latest_status=passed
  fi
  temporary="$logs/publication.json.tmp"
  jq --arg latest_status "$latest_status" --argjson xcode_alias "$xcode_alias" \
    '.tag_promotion = "passed" | .latest_promotion = $latest_status | .xcode_alias = $xcode_alias' \
    "$logs/publication.json" > "$temporary"
  mv "$temporary" "$logs/publication.json"
  temporary="$logs/result.json.tmp"
  jq '.stage = "published"' "$logs/result.json" > "$temporary"
  mv "$temporary" "$logs/result.json"
}

prune_published_bundle() {
  require_task
  jq -e '.stage == "published"' "$logs/result.json" >/dev/null || ci_die "Image publication has not completed"
  if [[ "$VARIANT" == vanilla ]]; then
    if ! .build/tools/image-artifact run --timeout 300 -- bash ci/image.sh cache-parent; then
      printf 'Could not retain the published parent image in the local cache\n' >&2
    fi
  fi
  printf 'Verifying the saved VM before removing its recovery bundle\n'
  remove_verified_bundle
}

cache_published_parent() {
  require_task
  [[ "$VARIANT" == vanilla ]] || ci_die "Only vanilla images are cached as parents"
  local digest
  digest=$(jq -er 'select(.stage == "published") | .manifest_digest' "$logs/result.json")
  parent_cache_store "$task_root/downloaded/layout" "$digest"
}

cleanup_task() {
  local cache
  local incomplete
  local recovery_digest=
  [[ -e "$task_root" ]] || return 0
  [[ -d "$RUNNER_TEMP" && ! -L "$RUNNER_TEMP" && -d "$task_root" && ! -L "$task_root" ]] || ci_die "Invalid task directory"
  require_task
  if [[ -d "$tart_home/vms" ]]; then
    local bundle
    while IFS= read -r bundle; do
      stop_vm "${bundle##*/}"
    done < <(find "$tart_home/vms" -mindepth 1 -maxdepth 1 -type d -print)
    require_closed_bundle "$tart_home/vms"
  fi
  cache=$(verified_directory "$BUILD_RUN")
  incomplete="$cache.incomplete-$run_key"
  require_verified_path "$cache"
  require_verified_path "$incomplete"
  if [[ -e "$incomplete" || -L "$incomplete" ]]; then
    [[ -d "$incomplete" && ! -L "$incomplete" ]] || ci_die "Invalid incomplete verified cache"
    rm -rf -- "$incomplete"
  fi
  if [[ -d "$cache" && ! -L "$cache" ]]; then
    if [[ ! -f "$logs/bundle.json" || ! -f "$logs/result.json" ]]; then
      if [[ "$BUILD_RUN" == "$run_key" ]]; then
        verify_bundle "$cache"
        rm -rf -- "$cache"
        cache=
      fi
    elif [[ $(ci_sha256 "$cache/bundle.json") != "$(ci_sha256 "$logs/bundle.json")" ]]; then
      ci_die "Verified cache metadata changed during the run"
    fi
  fi
  if [[ -n "$cache" && -d "$cache" && ! -L "$cache" ]]; then
    save_download_cache
    if [[ -f "$logs/result.json" ]]; then
      recovery_digest=$(jq -er '.recovery_expected_digest // ""' "$logs/result.json")
    fi
    if [[ -z "$recovery_digest" && $(jq -er '.stage // ""' "$logs/result.json" 2>/dev/null || true) == built ]]; then
      for path in "$cache/layout.incomplete-$run_key" "$cache/layout.json.tmp"; do
        if [[ -e "$path" || -L "$path" ]]; then
          [[ -d "$path" && ! -L "$path" ]] || [[ -f "$path" && ! -L "$path" ]] || ci_die "Invalid incomplete layout cache"
          rm -rf -- "$path"
        fi
      done
      if [[ -e "$cache/layout" || -L "$cache/layout" ]]; then
        [[ -d "$cache/layout" && ! -L "$cache/layout" ]] || ci_die "Invalid saved layout cache"
        rm -rf -- "$cache/layout"
      fi
      if [[ -e "$cache/layout.json" || -L "$cache/layout.json" ]]; then
        [[ -f "$cache/layout.json" && ! -L "$cache/layout.json" ]] || ci_die "Invalid saved layout metadata"
        rm -f -- "$cache/layout.json"
      fi
    fi
  fi
  rm -rf -- "$task_root"
  if [[ -e "$parent_cache_root" || -L "$parent_cache_root" ]]; then
    parent_cache_init
  fi
}

case ${1:-} in
  init) initialize ;;
  check) check_runner ;;
  build) build_image ;;
  restore) restore_image ;;
  prepare) prepare_publication ;;
  upload) upload_publication ;;
  verify) verify_publication ;;
  promote) promote_publication ;;
  complete) complete_publication ;;
  prune-published) prune_published_bundle ;;
  cache-parent) cache_published_parent ;;
  cleanup) cleanup_task ;;
  *) ci_die "Usage: ci/image.sh <init|check|build|restore|prepare|upload|verify|promote|complete|prune-published|cache-parent|cleanup>" ;;
esac
