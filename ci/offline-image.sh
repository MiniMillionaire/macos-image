#!/bin/bash
set -euo pipefail

[[ ${GITHUB_ACTIONS:-} == true && ${RUNNER_OS:-} == macOS && ${RUNNER_ARCH:-} == ARM64 ]]
[[ ${VARIANT:-} == vanilla || ${VARIANT:-} == base ]]
root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
cd "$root"
work="$RUNNER_TEMP/offline-image"
evidence="$RUNNER_TEMP/offline-evidence"
config="$root/config/miso/27.0.1"
mkdir -p "$work" "$evidence"
export PATH="$work/bin:$PATH"
export TART_HOME="$work/tart"
export TART_NO_AUTO_PRUNE=1
miso="$work/bin/miso"
tart="$work/bin/tart.app/Contents/MacOS/tart"
stage=${1:?Missing operation}

fetch() {
  local url=$1 output=$2 bytes=$3 digest=$4
  [[ ! -e "$output" ]]
  curl --fail --location --silent --show-error --proto '=https' --proto-redir '=https' \
    --connect-timeout 30 --max-time 3600 --retry 2 --retry-max-time 3900 \
    --max-filesize "$bytes" --output "$output.partial" "$url"
  [[ $(stat -f %z "$output.partial") == "$bytes" ]]
  [[ $(shasum -a 256 "$output.partial" | awk '{print $1}') == "$digest" ]]
  mv "$output.partial" "$output"
}

require_detached() {
  hdiutil info -plist > "$evidence/attachments.plist"
  plutil -convert json -o - "$evidence/attachments.plist" | jq -e --arg prefix "$work/" \
    '[.images[]? | select(."image-path" | startswith($prefix))] | length == 0' >/dev/null
}

prepare() {
  [[ ${BUILD_RUNNER_ENVIRONMENT:-} == github-hosted ]] || {
    printf '%s\n' 'Runner cleanup requires a GitHub-hosted environment.' >&2
    return 1
  }
  mkdir -p "$work/bin" "$work/packages" "$TART_HOME/vms"
  { sw_vers; uname -m; sysctl hw.model hw.memsize; xcodebuild -version; sudo -n id -u; } \
    > "$evidence/host.txt"
  gh release download "v$MISO_VERSION" --repo cocoa-xu/miso --pattern 'miso.tar.gz*' --dir "$work/bin"
  (cd "$work/bin" && shasum -a 256 -c miso.tar.gz.sha256 && tar -xzf miso.tar.gz)
  [[ $("$miso" --version) == "$MISO_VERSION" ]]
  codesign --verify --strict "$miso"
  cp "$work/bin/BUILD.txt" "$evidence/miso-build.txt"
  cp "$(command -v gh)" "$work/bin/gh"
  cp "$(command -v oras)" "$work/bin/oras"
  otool -L "$work/bin/gh" "$work/bin/oras" > "$evidence/tool-libraries.txt"
  if grep -q '/opt/homebrew/' "$evidence/tool-libraries.txt"; then
    printf '%s\n' 'Publication tools depend on the Homebrew directory scheduled for cleanup.' >&2
    return 1
  fi
  fetch https://github.com/openai/tart/releases/download/2.40.1/tart.tar.gz \
    "$work/tart.tar.gz" 22943905 363e2701154a8155cbc1bb6d845430c9b42697d2a186bc49574471ca2877db46
  tar -xzf "$work/tart.tar.gz" -C "$work/bin"
  codesign --verify --deep --strict "$work/bin/tart.app"
  { "$tart" --version; oras version; "$miso" --version; } > "$evidence/tools.txt"
  df -k / > "$evidence/space-before-cleanup.txt"
  xcrun simctl runtime delete all || true
  local selected path
  selected=$(cd "$DEVELOPER_DIR/../.." && pwd -P)
  for path in /Applications/Xcode*.app; do
    [[ -d "$path" && ! -L "$path" && "$path" != "$selected" ]] || continue
    sudo -n rm -r "$path"
  done
  for path in "$HOME/Library/Android" "$HOME/.android" "$HOME/.gradle" \
    "$HOME/.rustup" "$HOME/.cargo" "$HOME/Library/Caches/Homebrew" \
    "$HOME/Library/Caches/org.swift.swiftpm" /opt/homebrew \
    /usr/local/share/powershell /usr/local/share/dotnet /usr/local/lib/node_modules \
    /System/Library/AssetsV2/com_apple_MobileAsset_AppleDeveloperDocumentation; do
    if [[ -d "$path" && ! -L "$path" ]]; then sudo -n rm -r "$path"; fi
  done
  hash -r
  df -k / | tee "$evidence/space-after-cleanup.txt"
  [[ $(df -k "$work" | awk 'NR==2 {print $4}') -ge 93323264 ]]
  "$miso" config check "$config/image.json" > "$evidence/config-check.json"
}

download() {
  local filename url bytes digest
  while IFS=$'\t' read -r filename url bytes digest; do
    fetch "$url" "$work/packages/$filename" "$bytes" "$digest"
  done < "$config/clt.tsv"
}

restore() {
  sudo -n "$miso" restore \
    https://updates.cdn-apple.com/2026FallFCS/59241290-5d51-4ca8-9df4-31624b9a4eac/UniversalMac_27.0.1_26A434_Restore.ipsw \
    --packages "$work/packages" --config "$config/image.json" \
    --disk-bytes 68719476736 --output "$work/restore" | tee "$evidence/restore.json" >/dev/null
  jq -e '.profile.release == {version:"27.0.1",build:"26A434"}' "$evidence/restore.json" >/dev/null
  collect
  require_detached
  sudo -n mv "$work/restore/assembled/bundle" "$work/vanilla"
  if [[ "$VARIANT" == base ]]; then
    sudo -n mv "$work/restore/boot" "$work/boot"
    sudo -n mv "$work/restore/policy-material" "$work/policy-material"
  fi
  sudo -n rm -r "$work/restore" "$work/packages"
}

software() {
  "$miso" base prepare --target-version 27.0.1 --target-build 26A434 \
    --config "$config/base.json" --jobs 2 --output "$work/software" > "$evidence/software.json"
  cp "$work/software/preparation.json" "$evidence/software-preparation.json"
}

record() {
  local path=$1
  jq -n --arg path "$path" --argjson bytes "$(stat -f %z "$work/$path")" \
    --arg sha256 "$(shasum -a 256 "$work/$path" | awk '{print $1}')" \
    '{path:$path,bytes:$bytes,sha256:$sha256}'
}

base() {
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
    --arg python "$python" '{schemaVersion:1,target:{version:"27.0.1",build:"26A434"},
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
    --argjson formulae "$(jq '[.selectedRoots[]]|unique' "$work/software/core/resolution.json")" '
    {schemaVersion:1,target:{version:"27.0.1",build:"26A434"},username:"admin",steps:[
      {stage:"static",files:{runner:$runner,"runner-release":$release,"known-hosts":$hosts},directories:{}},
      {stage:"bootstrap",files:{archive:$bootstrap},directories:{}},
      {stage:"bottles",files:{resolution:$bottles},directories:{bottles:"software/bottles"},formulae:$formulae},
      {stage:"ruby",files:{plan:$ruby},directories:{inputs:"software/ruby"}},
      {stage:"packages",files:{plan:$packages},directories:{inputs:"software/packages"}},
      {stage:"taps",files:{plan:$taps},directories:{inputs:"software/taps"}},
      {stage:"gcm",files:{plan:$gcm},directories:{inputs:"software/gcm"}},
      {stage:"security",files:{plan:$security},directories:{boot:"boot",material:"policy-material"}},
      {stage:"settings",files:{plan:$settings},directories:{}},
      {stage:"certificates",files:{plan:$certificates},directories:{inputs:"plans"}}
    ]}' > "$work/recipe.json"
  cp "$work/recipe.json" "$evidence/recipe.json"
  sudo -n "$miso" base build --source "$work/vanilla" --recipe "$work/recipe.json" \
    --inputs "$work" --output "$work/base" | tee "$evidence/base.json" >/dev/null
}

export_image() {
  local source="$work/vanilla"
  if [[ "$VARIANT" == base ]]; then source="$work/base/11-cleanup/bundle"; fi
  sudo -n "$miso" bundle export-tart "$source" --output "$work/export" | tee "$evidence/export.json" >/dev/null
  sudo -n cp "$source/manifest.json" "$evidence/bundle-manifest.json"
  sudo -n chown -R "$(id -u):$(id -g)" "$work/export" "$evidence"
  mv "$work/export/vm" "$TART_HOME/vms/$VARIANT"
  "$tart" get "$VARIANT" --format json > "$evidence/tart-config.json"
  cp "$TART_HOME/vms/$VARIANT/config.json" "$evidence/source-config.json"
  collect
  require_detached
  local path
  for path in vanilla base software boot policy-material plans; do
    if [[ -d "$work/$path" ]]; then sudo -n rm -r "$work/$path"; fi
  done
}

publish() {
  local reference="ghcr.io/minimillionaire/macos-golden-gate-$VARIANT:miso-27.0.1-$GITHUB_RUN_ID-$GITHUB_RUN_ATTEMPT"
  "$tart" push "$VARIANT" "$reference" --concurrency 2 --chunk-size 2 \
    --label "org.opencontainers.image.source=https://github.com/$GITHUB_REPOSITORY" \
    --label "org.opencontainers.image.revision=$GITHUB_SHA" \
    --label dev.macos-image.version=27.0.1 --label dev.macos-image.build=26A434 \
    --label "dev.macos-image.variant=$VARIANT" --label "dev.macos-image.miso=$MISO_VERSION"
  printf '%s\n' "$reference" > "$evidence/reference.txt"
}

verify() {
  unset TART_REGISTRY_HOSTNAME TART_REGISTRY_USERNAME TART_REGISTRY_PASSWORD
  local reference digest directory name expected
  reference=$(cat "$evidence/reference.txt")
  printf '{}\n' > "$work/anonymous-registry.json"
  digest=$(oras resolve "$reference" --registry-config "$work/anonymous-registry.json")
  [[ "$digest" =~ ^sha256:[0-9a-f]{64}$ ]]
  reference="${reference%:*}@$digest"
  "$tart" delete "$VARIANT"
  export TART_HOME="$work/download-check"
  "$tart" clone "$reference" downloaded --concurrency 2
  directory="$TART_HOME/vms/downloaded"
  for name in disk.img nvram.bin; do
    expected=$(jq -er --arg name "$name" '.files[] | select(.path == $name) | .sha256' "$evidence/export.json")
    [[ $(shasum -a 256 "$directory/$name" | awk '{print $1}') == "$expected" ]]
  done
  jq -S '{hardwareModel,ecid,cpuCountMin,memorySizeMin,os,arch,diskFormat}' \
    "$evidence/source-config.json" > "$evidence/source-identity.json"
  jq -S '{hardwareModel,ecid,cpuCountMin,memorySizeMin,os,arch,diskFormat}' \
    "$directory/config.json" > "$evidence/downloaded-identity.json"
  cmp "$evidence/source-identity.json" "$evidence/downloaded-identity.json"
  jq -n --arg reference "$reference" --arg revision "$GITHUB_SHA" --arg variant "$VARIANT" \
    --arg run "$GITHUB_RUN_ID-$GITHUB_RUN_ATTEMPT" --arg miso "$MISO_VERSION" \
    '{reference:$reference,revision:$revision,variant:$variant,run:$run,miso:$miso,
      target:{version:"27.0.1",build:"26A434"},anonymousDownloadVerified:true,
      vmStarted:false,runtimeVerified:false}' > "$evidence/publication.json"
  printf 'Verified candidate: %s\n\nIndependent boot acceptance is pending.\n' "$reference" >> "$GITHUB_STEP_SUMMARY"
}

collect() {
  local directory path
  for directory in restore base software; do
    [[ -d "$work/$directory" ]] || continue
    sudo -n find "$work/$directory" -maxdepth 3 -name journal.json -type f -print0 |
      while IFS= read -r -d '' path; do
        sudo -n cat "$path" | jq -c \
          '{operation,status,error,vmStarted,stage:.metadata.stage,
            downloadedIPSWRemoved:.metadata.downloadedIPSWRemoved,
            commands:[.commands[]|{name,startedAt,finishedAt,error,result}]}'
      done > "$evidence/$directory-journals.jsonl"
    sudo -n find "$work/$directory" -maxdepth 3 -name journal.json -type f -print0 |
      while IFS= read -r -d '' path; do
        sudo -n cat "$path" | jq -r '.commands[]|select(.error != null or .result == null)|.stdout,.stderr' |
          while IFS= read -r log; do
            [[ "$log" == logs/* && "$log" != *..* ]] || continue
            printf '\n%s/%s\n' "${path%/journal.json}" "$log"
            sudo -n tail -c 8192 "${path%/journal.json}/$log"
          done
      done > "$evidence/$directory-failed-commands.txt"
  done
  df -k / > "$evidence/space-final.txt"
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
  prepare|download|restore|software|base|publish|verify|collect) "$stage" ;;
  export) export_image ;;
  *) printf 'Unknown operation: %s\n' "$stage" >&2; exit 2 ;;
esac
