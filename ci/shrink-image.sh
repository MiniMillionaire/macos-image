#!/bin/bash
set -euo pipefail

fail() { printf '%s\n' "$1" >&2; exit 1; }
root=$(cd "$(dirname "$0")" && pwd -P)
mode=shrink
if [[ ${1:-} == --check ]]; then mode=check; shift; fi
source=${1:?Tart image directory required}
receipt=${2:?Disk shrink receipt required}
disk="$source/disk.img"
[[ "$source" == /* && -d "$source" && ! -L "$source" && -f "$disk" && ! -L "$disk" ]] ||
  fail 'Expected a local raw image directory.'
jq -e '.os == "darwin" and (.diskFormat // "raw") == "raw"' "$source/config.json" >/dev/null
disk_state() { stat -f '%i %z %.9Fm %.9Fc' "$disk"; }
check_receipt() {
  [[ -f "$receipt" && ! -L "$receipt" ]] || fail 'Disk shrink receipt is missing.'
  jq -L "$root" -e --arg state "$(disk_state)" --argjson bytes "$(stat -f %z "$disk")" '
    include "disk-shrink";
    valid_disk_shrink and .afterBytes == $bytes and .diskState == $state
  ' "$receipt" >/dev/null || fail 'Disk shrink receipt does not match the current image.'
}
if [[ "$mode" == check || -e "$receipt" ]]; then check_receipt; exit 0; fi
opened_status=0
opened=$(lsof -t "$disk") || opened_status=$?
[[ "$opened_status" == 1 && -z "$opened" ]] || fail 'Image disk is open or its usage cannot be established.'
before=$(stat -f %z "$disk")
limits=$(perl -e 'alarm 60; exec @ARGV' diskutil image resize --plist "$disk") || fail 'Cannot determine the minimum image size.'
minimum=$(plutil -extract min raw - <<<"$limits")
[[ "$minimum" =~ ^[1-9][0-9]*$ && ${#minimum} -le 15 ]] || fail 'Invalid minimum image size.'
target=$(( (minimum + 8589934592 + 9999999999) / 10000000000 * 10000000000 ))
expected=$(( (target + 4095) / 4096 * 4096 ))
(( expected <= before )) || fail 'Image cannot retain the required free-space reserve without growing.'
perl -e 'alarm 600; exec @ARGV' diskutil image resize --size "$target" "$disk"
after=$(stat -f %z "$disk")
(( after == expected )) || fail 'Disk resize did not produce the required capacity.'
temporary=$(mktemp "${receipt}.XXXXXX")
trap 'rm -f "$temporary"' EXIT
jq -n --argjson before "$before" --argjson after "$after" --argjson minimum "$minimum" \
  --argjson target "$target" --arg state "$(disk_state)" \
  '{version:1,beforeBytes:$before,minimumBytes:$minimum,reserveBytes:8589934592,
    stepBytes:10000000000,targetBytes:$target,afterBytes:$after,diskState:$state}' > "$temporary"
mv "$temporary" "$receipt"
check_receipt
printf 'Shrank image from %s to %s bytes; minimum was %s bytes.\n' "$before" "$after" "$minimum"
