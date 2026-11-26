#!/usr/bin/env bash
set -euo pipefail

die() {
  echo "$*" >&2
  exit 1
}

[[ ${TARGET_DISK_SIZE_GB:-} =~ ^[1-9][0-9]*$ ]] || die 'Invalid target disk size'
layout=$(diskutil list -plist physical) || die 'Could not read the physical disk layout'
value() {
  printf '%s\n' "$layout" | plutil -extract "$1" raw -
}
prefix=AllDisksAndPartitions.0
[[ $(value "$prefix.Size") == $((TARGET_DISK_SIZE_GB * 1000000000)) ]] ||
  die 'Physical disk does not match the requested size'
[[ $(value "$prefix.Partitions.0.Content") == Apple_APFS_ISC ]] ||
  die 'Unexpected macOS partition layout'
[[ $(value "$prefix.Partitions.1.Content") == Apple_APFS ]] ||
  die 'Unexpected macOS partition layout'
[[ $(value "$prefix.Partitions.2.Content") == Apple_APFS_Recovery ]] ||
  die 'Unexpected macOS partition layout'
if value "$prefix.Partitions.3.Size" >/dev/null 2>&1 ||
  value AllDisksAndPartitions.1.Size >/dev/null 2>&1; then
  die 'Unexpected extra disk or partition'
fi
free_bytes=$(($(value "$prefix.Size") - $(value "$prefix.Partitions.0.Size") -
  $(value "$prefix.Partitions.1.Size") - $(value "$prefix.Partitions.2.Size")))
(( free_bytes >= 0 )) || die 'Partition sizes exceed the physical disk'
if (( free_bytes > 1048576 )); then
  sudo -n diskutil apfs resizeContainer "$(value "$prefix.Partitions.1.DeviceIdentifier")" 0 ||
    die 'Could not grow the APFS container'
fi
