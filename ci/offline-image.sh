#!/bin/bash
set -euo pipefail

[[ ${GITHUB_ACTIONS:-} == true && ${RUNNER_OS:-} == macOS && ${RUNNER_ARCH:-} == ARM64 ]] || exit 1
[[ ${VARIANT:-} == vanilla || ${VARIANT:-} == base || ${VARIANT:-} == xcode ]] || exit 1
[[ ${XCODE_FLAVOR:-full} == full || ${XCODE_FLAVOR:-full} == slim ]] || exit 1
[[ ${KEEP_PARENT_IMAGE:-false} == true || ${KEEP_PARENT_IMAGE:-false} == false ]] || exit 1
root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
cd "$root"
work="$RUNNER_TEMP/offline-image"
evidence="$RUNNER_TEMP/offline-evidence/$VARIANT"
[[ ${IMAGE_PROFILE:-} =~ ^[A-Za-z0-9][A-Za-z0-9._-]*$ && "$IMAGE_PROFILE" != *..* ]] || exit 1
[[ ${TARGET_VARIANT:-} == vanilla || ${TARGET_VARIANT:-} == base || ${TARGET_VARIANT:-} == xcode ]] || exit 1
config="$root/config/miso/$IMAGE_PROFILE"
[[ -d "$config" && ! -L "$config" ]] || exit 1
profile="$config/profile.json"
jq -e '.schemaVersion == 1 and
  (.target.version | test("^[0-9]+[.][0-9]+([.][0-9]+)?$")) and
  (.target.build | test("^[0-9]{2}[A-Z][0-9]+[a-z]?$")) and
  (.ipsw | test("^https://updates[.]cdn-apple[.]com/[^[:space:]]+[.]ipsw$")) and
  (.diskBytes | type == "number" and . >= 68719476736 and . <= 1099511627776 and . % 4096 == 0) and
  (.repository | test("^ghcr[.]io/minimillionaire/[a-z0-9][a-z0-9-]+$"))' "$profile" >/dev/null
target=$(jq -c .target "$profile")
os_version=$(jq -r .target.version "$profile")
os_build=$(jq -r .target.build "$profile")
repository=$(jq -r .repository "$profile")
package_variant=$VARIANT
if [[ "$VARIANT" == xcode && ${XCODE_FLAVOR:-full} == slim ]]; then package_variant=slim-xcode; fi
configuration_digest=$(jq -Sc . "$config/image.json" | shasum -a 256 | awk '{print $1}')
username=$(jq -er .username "$config/image.json")
mkdir -p "$work" "$evidence"
export PATH="$work/bin:$PATH"
images="$work/images"
miso="$work/bin/miso"
parent_cache="$HOME/.cache/macos-image/offline-parent"
stage=${1:?Missing operation}

privileged() {
  if [[ -n ${MISO_ROOT_COMMAND:-} ]]; then
    "$MISO_ROOT_COMMAND" "$@"
  else
    sudo -n "$@"
  fi
}

fetch() {
  local url=$1 output=$2 bytes=$3 digest=$4
  [[ ! -e "$output" ]] || exit 1
  curl --fail --location --silent --show-error --proto '=https' --proto-redir '=https' \
    --connect-timeout 30 --max-time 3600 --retry 2 --retry-max-time 3900 \
    --max-filesize "$bytes" --output "$output.partial" "$url"
  [[ $(stat -f %z "$output.partial") == "$bytes" ]] || exit 1
  [[ $(shasum -a 256 "$output.partial" | awk '{print $1}') == "$digest" ]] || exit 1
  mv "$output.partial" "$output"
}

require_detached() {
  hdiutil info -plist > "$evidence/attachments.plist"
  plutil -convert json -o - "$evidence/attachments.plist" | jq -e --arg prefix "$work/" \
    '[.images[]? | select(."image-path" | startswith($prefix))] | length == 0' >/dev/null
}

prepare() {
  [[ ${BUILD_RUNNER_ENVIRONMENT:-} == github-hosted ||
    ${BUILD_RUNNER_ENVIRONMENT:-} == self-hosted && "$TARGET_VARIANT" == xcode ]] || return 1
  if [[ -n ${PARENT_RUN:-} ]]; then
    [[ "$TARGET_VARIANT" != vanilla && "$PARENT_RUN" =~ ^[0-9]+$ ]] || return 1
  fi
  if [[ ${KEEP_PARENT_IMAGE:-false} == true ]]; then
    if [[ $BUILD_RUNNER_ENVIRONMENT != self-hosted || -z ${PARENT_RUN:-} ]]; then
      printf '%s\n' 'Keeping a parent image requires a parent build on a self-hosted runner.' >&2
      return 1
    fi
  fi
  if [[ "$TARGET_VARIANT" == xcode ]]; then
    [[ "$XCODE_VERSION" =~ ^[A-Za-z0-9][A-Za-z0-9._-]*$ && "$XCODE_VERSION" != *..* ]] || return 1
    [[ -f "$config/xcode-$XCODE_VERSION.json" && -f "$config/xcode-$XCODE_VERSION-inputs.json" ]] || return 1
  fi
  if [[ -n ${XCODE_TOOLS:-} ]]; then
    [[ "$TARGET_VARIANT" == xcode && -n ${PARENT_RUN:-} ]] || return 1
    [[ "$XCODE_TOOLS" == android ]] || return 1
  fi
  local installed_miso
  installed_miso=$(command -v miso)
  mkdir -p "$work/bin" "$work/packages" "$images" "$work/common-evidence"
  { sw_vers; uname -m; sysctl hw.model hw.memsize; xcodebuild -version; privileged id -u; } \
    > "$evidence/host.txt"
  install -m 755 "$installed_miso" "$miso"
  codesign --verify --strict "$miso"
  "$miso" bundle import-tart --help >/dev/null
  "$miso" bundle push --help >/dev/null
  "$miso" bundle pull --help >/dev/null
  printf 'version=%s\nsource=%s\n' "$("$miso" --version)" "$MISO_VERSION" > "$evidence/miso-build.txt"
  cp "$(command -v gh)" "$work/bin/gh"
  otool -L "$work/bin/gh" > "$evidence/tool-libraries.txt"
  if [[ $BUILD_RUNNER_ENVIRONMENT == github-hosted ]] && grep -q '/opt/homebrew/' "$evidence/tool-libraries.txt"; then
    printf '%s\n' 'Publication tools depend on the Homebrew directory scheduled for cleanup.' >&2
    return 1
  fi
  "$miso" --version > "$evidence/tools.txt"
  df -k / > "$evidence/space-before-cleanup.txt"
  if [[ $BUILD_RUNNER_ENVIRONMENT == github-hosted ]]; then
    xcrun simctl runtime delete all || true
    local selected path
    selected=$(cd "${DEVELOPER_DIR:-$(xcode-select -p)}/../.." && pwd -P)
    for path in /Applications/Xcode*.app; do
      [[ -d "$path" && ! -L "$path" && "$path" != "$selected" ]] || continue
      privileged rm -r "$path"
    done
    for path in "$HOME/Library/Android" "$HOME/.android" "$HOME/.gradle" \
      "$HOME/.rustup" "$HOME/.cargo" "$HOME/Library/Caches/Homebrew" \
      "$HOME/Library/Caches/org.swift.swiftpm" /opt/homebrew \
      /usr/local/share/powershell /usr/local/share/dotnet /usr/local/lib/node_modules \
      /System/Library/AssetsV2/com_apple_MobileAsset_AppleDeveloperDocumentation; do
      if [[ -d "$path" && ! -L "$path" ]]; then privileged rm -r "$path"; fi
    done
  fi
  hash -r
  df -k / | tee "$evidence/space-after-cleanup.txt"
  [[ $(df -k "$work" | awk 'NR==2 {print $4}') -ge 93323264 ]] || exit 1
  "$miso" config check "$config/image.json" > "$evidence/config-check.json"
  if [[ "$TARGET_VARIANT" != vanilla ]]; then
    for name in security settings; do
      jq -e --argjson target "$target" '.target == $target' "$config/$name.json" >/dev/null
    done
  fi
  cp "$evidence/"{host.txt,miso-build.txt,tools.txt,config-check.json} "$work/common-evidence/"
}

download() {
  local filename url bytes digest
  while IFS=$'\t' read -r filename url bytes digest; do
    fetch "$url" "$work/packages/$filename" "$bytes" "$digest"
  done < "$config/clt.tsv"
}

restore() {
  local disk_bytes
  disk_bytes=$(jq -r .diskBytes "$profile")
  if [[ "$TARGET_VARIANT" == xcode ]]; then
    disk_bytes=$(jq -er .diskBytes "$config/xcode-$XCODE_VERSION-inputs.json")
  fi
  privileged "$miso" restore \
    "$(jq -r .ipsw "$profile")" \
    --packages "$work/packages" --config "$config/image.json" \
    --disk-bytes "$disk_bytes" --output "$work/restore" | tee "$evidence/restore.json" >/dev/null
  jq -e --argjson target "$target" '.profile.release == $target' "$evidence/restore.json" >/dev/null
  collect
  require_detached
  privileged mv "$work/restore/assembled/bundle" "$work/vanilla"
  mkdir "$work/boot" "$work/policy-material"
  privileged cp "$work/restore/boot/journal.json" "$work/boot/"
  privileged cp "$work/restore/policy-material/journal.json" "$work/policy-material/"
  for name in key certificates payload; do
    privileged jq -e --arg name "$name" '.result.blobs[$name].path == ($name + ".der")' \
      "$work/policy-material/journal.json" >/dev/null
    privileged cp "$work/restore/policy-material/$name.der" "$work/policy-material/"
  done
  privileged rm -r "$work/restore" "$work/packages"
}

software() {
  "$miso" base prepare --target-version "$os_version" --target-build "$os_build" \
    --config "$config/base.json" --jobs 2 --output "$work/software" > "$evidence/software.json"
  cp "$work/software/preparation.json" "$evidence/software-preparation.json"
}

import_parent() {
  [[ "$TARGET_VARIANT" != vanilla && "$PARENT_RUN" =~ ^[0-9]+$ ]] || return 1
  local parent="$work/parent-evidence" reference attempt expected_manifest parent_variant manifest artifact parent_package
  parent_variant=vanilla
  if [[ "$TARGET_VARIANT" == xcode ]]; then parent_variant=base; fi
  if [[ -n ${XCODE_TOOLS:-} ]]; then parent_variant=xcode; fi
  gh api "repos/$GITHUB_REPOSITORY/actions/runs/$PARENT_RUN" > "$evidence/parent-run.json"
  jq -e '.status == "completed" and .head_branch == "main" and .event == "workflow_dispatch" and
    .path == ".github/workflows/offline-image.yml"' "$evidence/parent-run.json" >/dev/null
  attempt=$(jq -er .run_attempt "$evidence/parent-run.json")
  artifact="offline-$IMAGE_PROFILE-$parent_variant-$PARENT_RUN-$attempt"
  parent_package=$parent_variant
  if [[ "$parent_variant" == xcode ]]; then
    artifact="offline-$IMAGE_PROFILE-xcode-$XCODE_VERSION-$XCODE_FLAVOR-$PARENT_RUN-$attempt"
    if [[ "$XCODE_FLAVOR" == slim ]]; then parent_package=slim-xcode; fi
  fi
  gh run download "$PARENT_RUN" --repo "$GITHUB_REPOSITORY" \
    -n "$artifact" -D "$parent"
  if [[ "$parent_variant" == vanilla ]]; then
    manifest="$parent/construction/source-manifest.json"
    if [[ ! -f "$manifest" ]]; then manifest="$parent/bundle-manifest.json"; fi
    [[ -f "$manifest" ]] || return 1
  else
    manifest="$parent/bundle-manifest.json"
    [[ -f "$manifest" ]] || return 1
    if [[ "$parent_variant" == base ]]; then [[ -f "$parent/software-preparation.json" ]] || return 1; fi
    if [[ "$parent_variant" == xcode ]]; then
      local profile_options=(--config "$config/xcode-$XCODE_VERSION.json")
      if [[ "$XCODE_FLAVOR" == slim ]]; then profile_options+=(--slim); fi
      "$miso" xcode defaults "${profile_options[@]}" > "$evidence/parent-expected-xcode.json"
      jq -e --slurpfile expected "$evidence/parent-expected-xcode.json" \
        '.xcode_complete == true and .xcode_configuration == $expected[0]' "$manifest" >/dev/null
    fi
  fi
  local revision parent_configuration
  revision=$(jq -er .head_sha "$evidence/parent-run.json")
  gh api -H 'Accept: application/vnd.github.raw+json' \
    "repos/$GITHUB_REPOSITORY/contents/config/miso/$IMAGE_PROFILE/image.json?ref=$revision" \
    > "$evidence/parent-image-config.json"
  parent_configuration=$(jq -Sc . "$evidence/parent-image-config.json" | shasum -a 256 | awk '{print $1}')
  [[ "$parent_configuration" == "$configuration_digest" ]] || return 1
  jq -e --argjson target "$target" --arg variant "$parent_variant" \
    --arg configuration "$configuration_digest" --arg run "$PARENT_RUN-$attempt" --arg revision "$revision" '
    .variant == $variant and .target == $target and .run == $run and .revision == $revision and
    (.imageConfigurationSHA256 // $configuration) == $configuration and
    (.uploaded == true or .anonymousDownloadVerified == true) and .vmStarted == false and .runtimeVerified == false' \
    "$parent/publication.json" >/dev/null
  reference=$(jq -er .reference "$parent/publication.json")
  [[ "$reference" == "$repository-$parent_package@sha256:"* && "${reference##*@}" =~ ^sha256:[0-9a-f]{64}$ ]] || return 1
  expected_manifest=$(jq -er .sourceManifest.sha256 "$parent/export.json")
  [[ $(shasum -a 256 "$manifest" | awk '{print $1}') == "$expected_manifest" ]] || return 1
  local required_bytes=0 source_bytes
  if [[ "$TARGET_VARIANT" == xcode ]]; then
    required_bytes=$(jq -er .diskBytes "$config/xcode-$XCODE_VERSION-inputs.json")
  fi
  jq -n --arg reference "$reference" --arg manifest "$expected_manifest" --argjson bytes "$required_bytes" \
    '{reference:$reference,sourceManifest:$manifest,diskBytes:$bytes}' > "$work/parent-identity.json"
  if restore_parent_cache; then
    printf 'Reusing retained parent image: %s\n' "$reference"
    jq -n --arg reference "$reference" '{reference:$reference,reused:true}' > "$evidence/parent-download.json"
  else
    unset MISO_REGISTRY_USERNAME MISO_REGISTRY_PASSWORD
    if ! take_acceptance_source "$reference"; then
      "$miso" bundle pull "$reference" --output "$work/parent-download" \
        --concurrency "${MISO_TRANSFER_CONCURRENCY:-4}" > "$evidence/parent-download.json"
    fi
    source_bytes=$(stat -f %z "$work/parent-download/vm/disk.img")
    local import_options=(--manifest "$manifest" --output "$work/parent-import")
    if (( source_bytes < required_bytes )); then import_options+=(--disk-bytes "$required_bytes"); fi
    privileged "$miso" bundle import-tart "$work/parent-download/vm" \
      "${import_options[@]}" | tee "$evidence/import.json" >/dev/null
  fi
  local parent_source
  if [[ "$parent_variant" == vanilla ]]; then
    parent_source=vanilla
    privileged mv "$work/parent-import/bundle" "$work/vanilla"
    if [[ -f "$parent/construction/boot/journal.json" &&
      -f "$parent/construction/policy-material/journal.json" ]]; then
      cp -R "$parent/construction/boot" "$parent/construction/policy-material" "$work/"
    else
      privileged "$miso" base prepare-parent --source "$work/vanilla" \
        --output "$work/parent-boot" | tee "$evidence/parent-boot.json" >/dev/null
    fi
  elif [[ "$parent_variant" == base ]]; then
    parent_source=base/11-cleanup/bundle
    mkdir -p "$work/base/11-cleanup" "$RUNNER_TEMP/offline-evidence/base"
    privileged mv "$work/parent-import/bundle" "$work/base/11-cleanup/bundle"
    cp "$parent/software-preparation.json" "$RUNNER_TEMP/offline-evidence/base/"
  else
    parent_source=xcode-parent/bundle
    mkdir "$work/xcode-parent"
    privileged mv "$work/parent-import/bundle" "$work/xcode-parent/bundle"
    local receipt
    for receipt in archive.json gems.json prepare-casks.json prepare-tuist.json prepare-simulator-tools.json prepare-flutter.json; do
      cp "$parent/$receipt" "$evidence/$receipt"
    done
    cp "$parent/publication.json" "$evidence/inherited-xcode.json"
  fi
  cp "$parent/publication.json" "$work/parent-publication.json"
  printf '%s\n' "$parent_source" > "$work/parent-source.txt"
  require_detached
  if [[ -d "$work/parent-download/vm" ]]; then rm -r "$work/parent-download/vm"; fi
}

take_acceptance_source() {
  [[ ${BUILD_RUNNER_ENVIRONMENT:-} == self-hosted ]] || return 1
  local reference=$1 cache="$HOME/.cache/macos-image/acceptance/${1##*@sha256:}" file
  [[ -d "$cache" ]] || return 1
  [[ ! -L "$cache" && ! -L "$cache/vm" && $(cat "$cache/reference.txt") == "$reference" ]] || exit 1
  for file in disk.img nvram.bin config.json; do
    [[ -f "$cache/vm/$file" && ! -L "$cache/vm/$file" ]] || exit 1
  done
  stat -f '%i %z %b %m %c' "$cache/vm/"{disk.img,nvram.bin,config.json} > "$evidence/acceptance-source-state.txt"
  cmp "$cache/state.txt" "$evidence/acceptance-source-state.txt" || exit 1
  mkdir "$work/parent-download" || exit 1
  cp "$cache/download.json" "$evidence/parent-download.json" || exit 1
  mv "$cache/vm" "$work/parent-download/vm" || exit 1
  rm -r "$cache" || exit 1
  printf 'Reusing the unchanged source from VM acceptance: %s\n' "$reference"
}

parent_cache_directory() {
  local directory="$parent_cache"
  while [[ "$directory" != / ]]; do
    [[ ! -L "$directory" ]] || { printf 'Parent cache is a symbolic link: %s\n' "$directory" >&2; exit 1; }
    directory=$(dirname "$directory")
  done
  (umask 077; mkdir -p "$parent_cache") || exit 1
  [[ $(stat -f %u "$parent_cache") == "$(id -u)" ]] || exit 1
  [[ $(stat -f %d "$parent_cache") == "$(stat -f %d "$work")" ]] || {
    printf '%s\n' 'Parent cache and build workspace must be on the same volume.' >&2
    exit 1
  }
}

restore_parent_cache() {
  [[ ${BUILD_RUNNER_ENVIRONMENT:-} == self-hosted ]] || return 1
  parent_cache_directory
  if [[ ! -f "$parent_cache/identity.json" ]] ||
    ! cmp -s "$work/parent-identity.json" "$parent_cache/identity.json"; then
    privileged rm -r "$parent_cache" || exit 1
    return 1
  fi
  local file
  [[ ! -L "$parent_cache/bundle" ]] || exit 1
  for file in disk.img aux.bin hardware-model.bin machine-identifier.bin manifest.json; do
    privileged test ! -L "$parent_cache/bundle/$file" || exit 1
    if ! privileged test -f "$parent_cache/bundle/$file"; then
      printf '%s\n' 'Discarding incomplete parent cache.' >&2
      privileged rm -r "$parent_cache" || exit 1
      return 1
    fi
  done
  mkdir "$work/parent-import" || exit 1
  cp "$parent_cache/import.json" "$evidence/import.json" || exit 1
  privileged mv "$parent_cache/bundle" "$work/parent-import/bundle" || exit 1
  privileged rm -r "$parent_cache" || exit 1
}

retain_parent_image() {
  [[ ${KEEP_PARENT_IMAGE:-false} == true && -f "$work/parent-source.txt" ]] || return 0
  local source
  source=$(cat "$work/parent-source.txt")
  case "$source" in vanilla|base/11-cleanup/bundle|xcode-parent/bundle) ;; *) return 1 ;; esac
  privileged test -d "$work/$source" || return 0
  parent_cache_directory
  [[ ! -e "$parent_cache/bundle" && ! -L "$parent_cache/bundle" ]] || exit 1
  cp "$work/parent-identity.json" "$parent_cache/identity.json"
  cp "$evidence/import.json" "$parent_cache/import.json"
  privileged mv "$work/$source" "$parent_cache/bundle"
  printf 'Retained parent image: %s\n' "$parent_cache"
}

record() {
  local path=$1
  jq -n --arg path "$path" --argjson bytes "$(privileged stat -f %z "$work/$path")" \
    --arg sha256 "$(privileged shasum -a 256 "$work/$path" | awk '{print $1}')" \
    '{path:$path,bytes:$bytes,sha256:$sha256}'
}

base() {
  privileged test -f "$work/vanilla/manifest.json"
  local boot=boot material=policy-material
  if privileged test -f "$work/parent-boot/journal.json"; then
    boot="parent-boot"
    material="parent-boot"
  fi
  privileged test -f "$work/$boot/journal.json"
  privileged test -f "$work/$material/journal.json"
  privileged jq -e --argjson target "$target" '.target == $target and .construction_vm_started == false and
    .runtime_verified == false and (.base_complete != true) and (.xcode_stages == null)' \
    "$work/vanilla/manifest.json" >/dev/null
  jq -n --argjson manifest "$(record vanilla/manifest.json)" --argjson target "$target" \
    --arg reference "$(jq -er .reference "$work/parent-publication.json")" \
    '{target:$target,sourceManifest:$manifest,reference:$reference,vmStarted:false}' > "$evidence/parent.json"
  mkdir "$work/plans"
  cp "$root/data/github_known_hosts" "$work/plans/github_known_hosts"
  cp "$config/trust-snapshot.json" "$work/plans/trust-snapshot.json"
  local agent python snapshot classification runner
  agent=$(jq -er '.taps[].formulas[] | select(.name == "tart-guest-agent") |
    .version + (if .revision == 0 then "" else "_" + (.revision|tostring) end)' "$work/software/taps/plan.json")
  for name in security settings; do
    jq --arg version "$agent" '.tartVersion = $version' "$config/$name.json" > "$work/plans/$name.json"
  done
  snapshot=$(record plans/trust-snapshot.json)
  jq --arg hash "$(jq -r .sha256 <<< "$snapshot")" '.snapshot_sha256 = $hash' \
    "$config/trust-classification.json" > "$work/plans/trust-classification.json"
  classification=$(record plans/trust-classification.json)
  python=$(jq -er '[.formulae|keys[]|select(startswith("python@"))] |
    sort_by(split("@")[1]|split(".")|map(tonumber)) | last' "$work/software/core/resolution.json")
  jq -n --argjson snapshot "$(jq '.path = "trust-snapshot.json"' <<< "$snapshot")" \
    --argjson classification "$(jq '.path = "trust-classification.json"' <<< "$classification")" \
    --arg python "$python" --argjson target "$target" '{schemaVersion:1,target:$target,
      snapshot:$snapshot,classification:$classification,pythonFormula:$python,
      pythonExecutable:($python|sub("@";""))}' > "$work/plans/certificates.json"
  runner=$(jq -er '.runner.path' "$work/software/runner/resolution.json")
  jq -n --argjson runner "$(record "software/runner/$runner")" \
    --argjson release "$(record software/runner/release.json)" \
    --argjson hosts "$(record plans/github_known_hosts)" \
    --argjson bootstrap "$(record software/bootstrap/archive.json)" \
    --argjson bottles "$(record software/core/resolution.json)" \
    --argjson ruby "$(record software/ruby/plan.json)" \
    --argjson packages "$(record software/packages/plan.json)" \
    --argjson taps "$(record software/taps/plan.json)" \
    --argjson gcm "$(record software/gcm/plan.json)" \
    --argjson security "$(record plans/security.json)" \
    --argjson settings "$(record plans/settings.json)" \
    --argjson certificates "$(record plans/certificates.json)" \
    --argjson target "$target" --arg username "$username" --arg boot "$boot" --arg material "$material" \
    --argjson formulae "$(jq '[.selectedRoots[]]|unique' "$work/software/core/resolution.json")" '
    {schemaVersion:1,target:$target,username:$username,steps:[
      {stage:"static",files:{runner:$runner,"runner-release":$release,"known-hosts":$hosts},directories:{}},
      {stage:"bootstrap",files:{archive:$bootstrap},directories:{}},
      {stage:"bottles",files:{resolution:$bottles},directories:{bottles:"software/bottles"},formulae:$formulae},
      {stage:"ruby",files:{plan:$ruby},directories:{inputs:"software/ruby"}},
      {stage:"packages",files:{plan:$packages},directories:{inputs:"software/packages"}},
      {stage:"taps",files:{plan:$taps},directories:{inputs:"software/taps"}},
      {stage:"gcm",files:{plan:$gcm},directories:{inputs:"software/gcm"}},
      {stage:"security",files:{plan:$security},directories:{boot:$boot,material:$material}},
      {stage:"settings",files:{plan:$settings},directories:{}},
      {stage:"certificates",files:{plan:$certificates},directories:{inputs:"plans"}}
    ]}' > "$work/recipe.json"
  cp "$work/recipe.json" "$evidence/recipe.json"
  privileged "$miso" base build --source "$work/vanilla" --recipe "$work/recipe.json" \
    --inputs "$work" --output "$work/base" | tee "$evidence/base.json" >/dev/null
}

export_image() {
  local source="$work/vanilla"
  if [[ "$VARIANT" == base ]]; then source="$work/base/11-cleanup/bundle"; fi
  if [[ "$VARIANT" == xcode ]]; then source="$work/xcode/final/image/bundle"; fi
  privileged "$miso" bundle export-tart "$source" --output "$work/export-$VARIANT" | tee "$evidence/export.json" >/dev/null
  privileged cp "$source/manifest.json" "$evidence/bundle-manifest.json"
  privileged chown -R "$(id -u):$(id -g)" "$work/export-$VARIANT" "$evidence"
  mv "$work/export-$VARIANT/vm" "$images/$VARIANT"
  cp "$images/$VARIANT/config.json" "$evidence/source-config.json"
  jq -S '{hardwareModel,ecid,cpuCountMin,memorySizeMin,os,arch,diskFormat}' \
    "$evidence/source-config.json" > "$evidence/source-identity.json"
  collect
  require_detached
  if [[ "$VARIANT" == vanilla ]]; then
    mkdir -p "$evidence/construction"
    privileged cp "$source/manifest.json" "$evidence/construction/source-manifest.json"
    privileged cp -R "$work/boot" "$work/policy-material" "$evidence/construction/"
    privileged chown -R "$(id -u):$(id -g)" "$evidence/construction"
    [[ "$TARGET_VARIANT" == vanilla ]] || return 0
  fi
  local path
  if [[ "$VARIANT" == base && "$TARGET_VARIANT" == xcode ]]; then return 0; fi
  retain_parent_image
  for path in vanilla base software boot policy-material parent-boot plans xcode-inputs xcode-parent xcode; do
    if [[ -d "$work/$path" ]]; then privileged rm -r "$work/$path"; fi
  done
}

publish() {
  local tag="miso-$os_version" reference
  if [[ "$VARIANT" == xcode ]]; then tag="$tag-xcode-$XCODE_VERSION"; fi
  reference="$repository-$package_variant:$tag-$GITHUB_RUN_ID-$GITHUB_RUN_ATTEMPT"
  "$miso" bundle push "$images/$VARIANT" "$reference" \
    --output "$work/upload-$VARIANT" --concurrency "${MISO_TRANSFER_CONCURRENCY:-4}" \
    --label "org.opencontainers.image.source=https://github.com/$GITHUB_REPOSITORY" \
    --label "org.opencontainers.image.revision=$GITHUB_SHA" \
    --label "dev.macos-image.version=$os_version" --label "dev.macos-image.build=$os_build" \
    --label "dev.macos-image.variant=$VARIANT" --label "dev.macos-image.miso=$MISO_VERSION" > "$evidence/upload.json"
  printf '%s\n' "$reference" > "$evidence/reference.txt"
  local candidate="$reference"
  reference=$(jq -er .reference "$evidence/upload.json")
  [[ "$reference" == "${candidate%:*}@sha256:"* && "${reference##*@}" =~ ^sha256:[0-9a-f]{64}$ ]] || exit 1
  jq -n --arg reference "$reference" --arg revision "$GITHUB_SHA" --arg variant "$VARIANT" \
    --arg run "$GITHUB_RUN_ID-$GITHUB_RUN_ATTEMPT" --arg miso "$MISO_VERSION" --argjson target "$target" \
    --arg profile "$IMAGE_PROFILE" --arg configuration "$configuration_digest" --arg xcode "${XCODE_VERSION:-}" \
    --arg flavor "${XCODE_FLAVOR:-full}" \
    '{reference:$reference,revision:$revision,variant:$variant,run:$run,miso:$miso,
      target:$target,profile:$profile,imageConfigurationSHA256:$configuration,uploaded:true,anonymousDownloadVerified:false,
      vmStarted:false,runtimeVerified:false,xcodeVersion:(if $variant == "xcode" then $xcode else null end),
      xcodeFlavor:(if $variant == "xcode" then $flavor else null end)}' > "$evidence/publication.json"
  if [[ "$VARIANT" != xcode ]]; then cp "$evidence/publication.json" "$work/parent-publication.json"; fi
  require_detached
  rm -r "${images:?}/${VARIANT:?}"
  printf 'Uploaded candidate: %s\n\nDownload and VM acceptance are pending.\n' "$reference" >> "$GITHUB_STEP_SUMMARY"
}

collect() {
  if [[ -f "$work/common-evidence/host.txt" ]]; then cp "$work/common-evidence/"* "$evidence/"; fi
  local directory path
  for directory in restore base software parent-boot xcode-inputs xcode; do
    [[ -d "$work/$directory" ]] || continue
    privileged find "$work/$directory" -maxdepth 3 -name journal.json -type f -print0 |
      while IFS= read -r -d '' path; do
        privileged cat "$path" | jq -c \
          '{operation,status,error,vmStarted,stage:.metadata.stage,
            downloadedIPSWRemoved:.metadata.downloadedIPSWRemoved,
            commands:[.commands[]|{name,startedAt,finishedAt,error,result}]}'
      done > "$evidence/$directory-journals.jsonl"
    privileged find "$work/$directory" -maxdepth 3 -name journal.json -type f -print0 |
      while IFS= read -r -d '' path; do
        privileged cat "$path" | jq -r '.commands[]|select(.error != null or .result == null)|.stdout,.stderr' |
          while IFS= read -r log; do
            [[ "$log" == logs/* && "$log" != *..* ]] || continue
            printf '\n%s/%s\n' "${path%/journal.json}" "$log"
            privileged tail -c 8192 "${path%/journal.json}/$log"
          done
      done > "$evidence/$directory-failed-commands.txt"
  done
  df -k / > "$evidence/space-final.txt"
}

cleanup() {
  [[ "$work" == "$RUNNER_TEMP/offline-image" && ! -L "$work" ]] || exit 1
  require_detached
  retain_parent_image
  privileged rm -r "$work"
}

finish() {
  local status=$?
  if [[ -n ${monitor_pid:-} ]]; then kill "$monitor_pid" 2>/dev/null || true; wait "$monitor_pid" 2>/dev/null || true; fi
  printf 'exit=%s\n' "$status" > "$evidence/$stage.status"
  df -k / > "$evidence/space-after-$stage.txt"
}
trap finish EXIT
(
  while true; do
    printf '%s\t%s\t%s\n' "$(date -u +%FT%TZ)" "$stage" "$(df -k "$work" | awk 'NR==2 {print $4}')" >> "$evidence/space-samples.tsv"
    sleep 60
  done
) &
monitor_pid=$!
case "$stage" in
  prepare|download|restore|software|base|publish|collect|cleanup) "$stage" ;;
  export) export_image ;;
  import) import_parent ;;
  xcode-inputs) bash "$root/ci/offline-xcode.sh" prepare ;;
  xcode) bash "$root/ci/offline-xcode.sh" build ;;
  *) printf 'Unknown operation: %s\n' "$stage" >&2; exit 2 ;;
esac
