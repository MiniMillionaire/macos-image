#!/bin/bash
set -euo pipefail

[[ ${GITHUB_ACTIONS:-} == true && ${TARGET_VARIANT:-} == xcode ]] || exit 1
[[ ${IMAGE_PROFILE:-} =~ ^[A-Za-z0-9][A-Za-z0-9._-]*$ && "$IMAGE_PROFILE" != *..* ]] || exit 1
[[ ${XCODE_VERSION:-} =~ ^[A-Za-z0-9][A-Za-z0-9._-]*$ && "$XCODE_VERSION" != *..* ]] || exit 1
root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
work="$RUNNER_TEMP/offline-image"
evidence="$RUNNER_TEMP/offline-evidence/xcode"
config="$root/config/miso/$IMAGE_PROFILE"
xcode="$config/xcode-$XCODE_VERSION.json"
requirements="$config/xcode-$XCODE_VERSION-inputs.json"
inputs="$work/xcode-inputs"
miso="$work/bin/miso"
target_version=$(jq -er .target.version "$config/profile.json")
target_build=$(jq -er .target.build "$config/profile.json")
username=$(jq -er .username "$config/image.json")
mkdir -p "$evidence"
jq -e --argjson platforms "$(jq .platforms "$xcode")" '.schemaVersion == 1 and
  (.diskBytes | type == "number" and . >= 64000000000 and . <= 2000000000000 and . % 1000000000 == 0) and
  (.runtimes | map(.platform) | sort) == ($platforms | sort) and
  (.formulae | type == "array" and length > 0)' "$requirements" >/dev/null

privileged() {
  if [[ -n ${MISO_ROOT_COMMAND:-} ]]; then "$MISO_ROOT_COMMAND" "$@"; else sudo -n "$@"; fi
}

prepare() {
  mkdir "$inputs"
  cp "$xcode" "$requirements" "$evidence/"
  "$miso" xcode prepare-archive --target-version "$target_version" --target-build "$target_build" \
    --config "$xcode" --output "$inputs/archive" > "$evidence/archive.json"
  local formula arguments=()
  while IFS= read -r formula; do arguments+=(--formula "$formula"); done < <(jq -er '.formulae[]' "$requirements")
  "$miso" base resolve --target-version "$target_version" --target-build "$target_build" \
    --xcode-config "$xcode" "${arguments[@]}" --output "$inputs/resolution" > "$evidence/bottle-resolution.json"
  "$miso" base bottles download --resolution "$inputs/resolution" --output "$inputs/bottles" > "$evidence/bottles.json"
  local versions="$RUNNER_TEMP/offline-evidence/base/software-preparation.json"
  "$miso" xcode prepare-gems --ruby-version "$(jq -er .versions.ruby "$versions")" \
    --rubygems-version "$(jq -er .versions.rubygems "$versions")" \
    --bundler-version "$(jq -er .versions.bundler "$versions")" --output "$inputs/gems" > "$evidence/gems.json"
  local tool
  for tool in casks simulator-tools tuist android flutter; do
    "$miso" xcode "prepare-$tool" --target-version "$target_version" --target-build "$target_build" \
      --output "$inputs/$tool" > "$evidence/prepare-$tool.json"
  done
}

require_detached() {
  hdiutil info -plist | plutil -convert json -o - - | jq -e --arg prefix "$work/" \
    '[.images[]? | select(."image-path" | startswith($prefix))] | length == 0' >/dev/null
}

install_stage() {
  local name=$1 layout=$2
  shift 2
  printf 'Installing Xcode stage: %s\n' "$name"
  privileged "$miso" xcode "$@" --source "$previous" --output "$work/xcode/$name" \
    | tee "$evidence/install-$name.json" >/dev/null
  local next="$work/xcode/$name/$layout"
  privileged jq -e '.construction_vm_started == false and .runtime_verified == false' "$next/manifest.json" >/dev/null
  require_detached
  if [[ "$previous" == "$work/xcode/"* ]]; then privileged rm "$previous/disk.img"; fi
  previous="$next"
}

build() {
  local previous="$work/base/11-cleanup/bundle" platform version runtime_build runtime_name
  mkdir "$work/xcode"
  install_stage application bundle install-application --prepared "$inputs/archive"
  install_stage packages bundle install-packages --prepared "$inputs/archive"
  rm -r "$inputs/archive"
  install_stage bottles bundle install-bottles --resolution "$inputs/resolution" --bottles "$inputs/bottles" --username "$username"
  rm -r "$inputs/bottles"
  install_stage gems bundle install-gems --prepared "$inputs/gems" --config "$xcode" --username "$username"
  rm -r "$inputs/gems"
  install_stage casks image/bundle install-casks --prepared "$inputs/casks" --username "$username"
  rm -r "$inputs/casks"
  local tool
  for tool in simulator-tools tuist android flutter; do
    install_stage "$tool" image/bundle "install-$tool" --prepared "$inputs/$tool" --config "$xcode" --username "$username"
    rm -r "${inputs:?}/$tool"
  done
  if jq -e '.components | index("MetalToolchain") != null' "$xcode" >/dev/null; then
    privileged "$miso" xcode prepare-metal --config "$xcode" --output "$inputs/metal" \
      | tee "$evidence/prepare-metal.json" >/dev/null
    install_stage metal image/bundle install-metal --prepared "$inputs/metal" --config "$xcode" --username "$username"
    privileged rm -r "$inputs/metal"
  fi
  while IFS=$'\t' read -r platform version runtime_build; do
    runtime_name="runtime-$platform"
    privileged "$miso" xcode prepare-runtime --platform "$platform" --runtime-version "$version" \
      --runtime-build "$runtime_build" --config "$xcode" --output "$inputs/$runtime_name" \
      | tee "$evidence/prepare-$runtime_name.json" >/dev/null
    install_stage "$runtime_name" image/bundle install-runtime --prepared "$inputs/$runtime_name" --config "$xcode" --username "$username"
    privileged rm -r "$inputs/$runtime_name"
  done < <(jq -r '.runtimes[] | [.platform,.version,.build] | @tsv' "$requirements")
  install_stage final image/bundle complete --config "$xcode" --username "$username"
  privileged jq -e --argjson configuration "$(cat "$xcode")" \
    '.xcode_complete == true and .xcode_configuration == $configuration' "$previous/manifest.json" >/dev/null
}

case ${1:?Missing operation} in
  prepare) prepare ;;
  build) build ;;
  *) exit 2 ;;
esac
