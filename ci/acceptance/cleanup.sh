#!/bin/bash
set -euo pipefail
root=$(cd "$(dirname "$0")/../.." && pwd -P)
source "$root/ci/image-storage.sh"
image_storage_paths
work="${ACCEPTANCE_WORKSPACE:-}"
[[ "$work" == "$IMAGE_ACCEPTANCE_WORKSPACE" && -d "$work" && ! -L "$work" ]] || exit 0
image_storage_require_directory "$work"
export TART_HOME="$work/tart"
tart="$work/tools/tart.app/Contents/MacOS/tart"
if [[ -x "$tart" && -d "$TART_HOME/vms/acceptance" ]]; then
  if "$tart" get acceptance --format json | jq -e '.Running == true' >/dev/null; then
    "$tart" stop acceptance --timeout 30
  fi
  "$tart" get acceptance --format json | jq -e '.State == "stopped" and .Running == false' >/dev/null
fi
hdiutil info -plist | plutil -convert json -o - - | jq -e --arg path "$work/" \
  '[.images[]? | select(."image-path" | startswith($path))] | length == 0' >/dev/null
if [[ -f "$work/evidence/source-cache.txt" ]]; then
  cache=$(cat "$work/evidence/source-cache.txt")
  reference=$(jq -er .reference "$work/cloud/publication.json")
  [[ "$reference" =~ @sha256:[0-9a-f]{64}$ ]] || exit 1
  [[ "$cache" == "$IMAGE_CACHE_ROOT/acceptance/${reference##*@sha256:}" && ! -L "$cache" ]] || exit 1
  image_storage_require_directory "$cache"
  if [[ -f "$work/evidence/acceptance.json" && ${KEEP_SOURCE_IMAGE:-false} != true ]]; then
    rm -r "${cache:?}"
  elif [[ -f "$work/evidence/acceptance.json" ]]; then
    printf 'Retained the unchanged source for the next build.\n'
  else
    printf 'Retained the downloaded source for another VM acceptance attempt.\n'
  fi
fi
for path in tart download tools; do
  if [[ -d "$work/$path" ]]; then rm -r "${work:?}/$path"; fi
done
df -h "$work" > "$work/evidence/space-cleaned.txt"
