#!/bin/bash
set -euo pipefail
work=${ACCEPTANCE_WORKSPACE:?}
[[ "$work" == "$RUNNER_TEMP/"* && -d "$work" && ! -L "$work" ]] || exit 0
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
for path in tart download tools; do
  if [[ -d "$work/$path" ]]; then rm -r "${work:?}/$path"; fi
done
df -h /System/Volumes/Data > "$work/evidence/space-cleaned.txt"
