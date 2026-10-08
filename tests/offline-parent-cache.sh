#!/bin/bash
# shellcheck disable=SC1091,SC2034,SC2154
set -euo pipefail
root=$(cd "$(dirname "$0")/../" && pwd)
fixture=$(cd "$(mktemp -d)" && pwd -P)
trap 'rm -rf "$fixture"' EXIT
sed -n '/^privileged() {/,/^finish() {/p' "$root/ci/offline-image.sh" | sed '$d' > "$fixture/functions.sh"
source "$fixture/functions.sh"
privileged() {
  local argument
  for argument in "$@"; do
    if [[ "$argument" == /* && "$argument" != "$fixture" && "$argument" != "$fixture/"* ]]; then
      printf 'Refusing fixture command outside its temporary directory: %s\n' "$argument" >&2
      return 99
    fi
  done
  "$@"
}
require_detached() { :; }
collect() { :; }
export FIXTURE="$fixture"
parent_cache_root="$fixture/cache/offline-parents"
legacy_parent_cache="$fixture/cache/offline-parent"
RUNNER_TEMP="$fixture/temp"
work="$RUNNER_TEMP/offline-image"
evidence="$RUNNER_TEMP/offline-evidence/xcode"
images="$work/images"
config="$root/config/miso/27.0.1"
IMAGE_PROFILE=27.0.1
TARGET_VARIANT=xcode
VARIANT=xcode
XCODE_VERSION=27.1-rc
XCODE_TOOLS=
PARENT_RUN=123
GITHUB_REPOSITORY=MiniMillionaire/macos-image
BUILD_RUNNER_ENVIRONMENT=self-hosted
KEEP_PARENT_IMAGE=true
target=$(jq -c .target "$config/profile.json")
repository=$(jq -r .repository "$config/profile.json")
configuration_digest=$(jq -Sc . "$config/image.json" | shasum -a 256 | awk '{print $1}')
mkdir -p "$fixture/artifact"
printf '{"test":"source"}\n' > "$fixture/artifact/bundle-manifest.json"
digest=$(shasum -a 256 "$fixture/artifact/bundle-manifest.json" | awk '{print $1}')
jq -n --arg hash "$digest" '{sourceManifest:{sha256:$hash}}' > "$fixture/artifact/export.json"
jq -n --arg reference "$repository-base@sha256:$digest" --argjson target "$target" \
  --arg config "$configuration_digest" '{reference:$reference,target:$target,variant:"base",
    revision:"abc123",run:"123-1",imageConfigurationSHA256:$config,
    uploaded:true,vmStarted:false,runtimeVerified:false}' > "$fixture/artifact/publication.json"
printf '{}\n' > "$fixture/artifact/software-preparation.json"
gh() {
  if [[ $1 == run ]]; then
    cp -R "$fixture/artifact" "$work/parent-evidence"
  elif [[ $2 == repos/*/actions/runs/* ]]; then
    printf '%s\n' '{"status":"completed","head_branch":"main","event":"workflow_dispatch","path":".github/workflows/offline-image.yml","run_attempt":1,"head_sha":"abc123"}'
  else
    cat "$config/image.json"
  fi
}
cat > "$fixture/miso" <<'MOCK'
#!/bin/bash
set -euo pipefail
operation=$2
shift 2
while (( $# )); do
  case "$1" in --output) output=$2; shift 2 ;; *) shift ;; esac
done
case "$operation" in
  pull)
    printf 'pull\n' >> "$FIXTURE/transfers"
    mkdir -p "$output/vm"
    printf 'disk\n' > "$output/vm/disk.img"
    ;;
  import-tart)
    printf 'import\n' >> "$FIXTURE/imports"
    mkdir -p "$output/bundle"
    for file in disk.img aux.bin hardware-model.bin machine-identifier.bin manifest.json; do
      printf '%s\n' "$file" > "$output/bundle/$file"
    done
    ;;
  export-tart)
    mkdir -p "$output/vm"
    printf '{}\n' > "$output/vm/config.json"
    printf 'exported disk\n' > "$output/vm/disk.img"
    ;;
  *) exit 1 ;;
esac
printf '{}\n'
MOCK
chmod +x "$fixture/miso"
miso="$fixture/miso"
new_job() {
  mkdir -p "$work" "$evidence" "$images"
  import_parent
}
finish_build() {
  mkdir -p "$work/xcode/final/image/bundle" "$work/xcode-inputs"
  printf '{}\n' > "$work/xcode/final/image/bundle/manifest.json"
  export_image
  [[ ! -e "$work/xcode-inputs" && ! -e "$work/xcode" && -d "$images/xcode" ]]
}
new_job
disk="$work/base/11-cleanup/bundle/disk.img"
inode=$(stat -f %i "$disk")
finish_build
[[ ! -e "$disk" && $(stat -f %i "$parent_cache/bundle/disk.img") == "$inode" ]]
cleanup
[[ -d "$parent_cache/bundle" && ! -e "$work" ]]
rm -r "$RUNNER_TEMP"
new_job
[[ $(stat -f %i "$disk") == "$inode" && ! -e "$parent_cache" ]]
jq -e '.reused == true' "$evidence/parent-download.json" >/dev/null
[[ $(wc -l < "$fixture/transfers") -eq 1 && $(wc -l < "$fixture/imports") -eq 1 ]]
cleanup
[[ -d "$parent_cache/bundle" ]]
rm -r "$RUNNER_TEMP"
KEEP_PARENT_IMAGE=false
new_job
[[ $(stat -f %i "$disk") == "$inode" ]]
finish_build
cleanup
[[ ! -e "$parent_cache" && ! -e "$work" && $(wc -l < "$fixture/transfers") -eq 1 ]]
printf '%s\n' 'PASS: three jobs, one pull/import, same inode, retained after failure cleanup, removed by default on final job.'
rm -r "$RUNNER_TEMP"
KEEP_PARENT_IMAGE=true
new_job
cleanup
cp "$parent_cache/identity.json" "$fixture/identity.json"
jq '.diskBytes += 1' "$fixture/identity.json" > "$parent_cache/identity.json"
rm -r "$RUNNER_TEMP"
new_job
[[ $(wc -l < "$fixture/transfers") -eq 3 ]]
cleanup
printf '%s\n' 'PASS: changed identity replaces the old cache.'
rm "$parent_cache/bundle/aux.bin"
rm -r "$RUNNER_TEMP"
new_job
[[ $(wc -l < "$fixture/transfers") -eq 4 ]]
cleanup
printf '%s\n' 'PASS: incomplete cache is discarded and downloaded again.'
first_cache="$parent_cache"
first_inode=$(stat -f %i "$first_cache/bundle/disk.img")
cp "$fixture/artifact/publication.json" "$fixture/original-publication.json"
second_digest=$(printf '%064d' 7)
jq --arg ref "$repository-base@sha256:$second_digest" '.reference = $ref' \
  "$fixture/original-publication.json" > "$fixture/artifact/publication.json"
rm -r "$RUNNER_TEMP"
new_job
cleanup
second_cache="$parent_cache"
[[ "$first_cache" != "$second_cache" && -f "$first_cache/bundle/disk.img" && -f "$second_cache/bundle/disk.img" ]]
cp "$fixture/original-publication.json" "$fixture/artifact/publication.json"
rm -r "$RUNNER_TEMP"
new_job
[[ $(stat -f %i "$disk") == "$first_inode" && $(wc -l < "$fixture/transfers") -eq 5 ]]
cleanup
mv "$first_cache" "$legacy_parent_cache"
rm -r "$RUNNER_TEMP"
new_job
[[ ! -e "$legacy_parent_cache" && $(stat -f %i "$disk") == "$first_inode" ]]
KEEP_PARENT_IMAGE=false
cleanup
[[ ! -e "$first_cache" && -f "$second_cache/bundle/disk.img" && $(wc -l < "$fixture/transfers") -eq 5 ]]
printf '%s\n' 'PASS: separate parents survive switching; legacy cache migrates without copying; default cleanup removes only the selected parent.'
mkdir -p "$parent_cache"
rm -r "$parent_cache"
mkdir -p "$work"
cp "$fixture/identity.json" "$work/parent-identity.json"
ln -s "$fixture/artifact" "$parent_cache"
if (parent_cache_directory); then exit 1; fi
[[ -f "$fixture/artifact/bundle-manifest.json" ]]
printf '%s\n' 'PASS: a symlink cache is rejected without deleting its target.'
KEEP_PARENT_IMAGE=true
if (BUILD_RUNNER_ENVIRONMENT=github-hosted; prepare); then exit 1; fi
if (PARENT_RUN=; prepare); then exit 1; fi
printf '%s\n' 'PASS: retention rejects hosted runners and missing parent selections.'
