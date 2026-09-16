#!/usr/bin/env bash
set -euo pipefail

die() {
  echo "$*" >&2
  exit 1
}

[[ ${TARGET_DISK_SIZE_GB:-} =~ ^[1-9][0-9]*$ ]] || die 'Invalid target disk size'

disk_plist=$(diskutil list -plist physical)
plist_value() {
  printf '%s\n' "$disk_plist" | plutil -extract "$1" raw -
}

prefix=AllDisksAndPartitions.0
disk_bytes=$(plist_value "$prefix.Size")
isc_bytes=$(plist_value "$prefix.Partitions.0.Size")
system_bytes=$(plist_value "$prefix.Partitions.1.Size")
recovery_bytes=$(plist_value "$prefix.Partitions.2.Size")

[[ $(plist_value "$prefix.Partitions.0.Content") == Apple_APFS_ISC ]] || die 'Unexpected iBoot partition'
[[ $(plist_value "$prefix.Partitions.1.Content") == Apple_APFS ]] || die 'Unexpected system partition'
[[ $(plist_value "$prefix.Partitions.2.Content") == Apple_APFS_Recovery ]] || die 'Unexpected recovery partition'
if plist_value "$prefix.Partitions.3.Size" >/dev/null 2>&1; then
  die 'Unexpected extra disk partition'
fi

[[ $disk_bytes -eq $((TARGET_DISK_SIZE_GB * 1000000000)) ]] || die 'Physical disk size does not match target'
gap_bytes=$((disk_bytes - isc_bytes - system_bytes - recovery_bytes))
(( gap_bytes >= 0 && gap_bytes <= 1048576 )) || die "Unallocated disk space remains: $gap_bytes bytes"

data_kib=$(df -k /System/Volumes/Data | awk 'NR == 2 { print $2 }')
[[ $data_kib =~ ^[1-9][0-9]*$ ]] || die 'Could not read Data filesystem capacity'
data_bytes=$((data_kib * 1024))
(( data_bytes >= system_bytes - 67108864 && data_bytes <= system_bytes )) ||
  die 'Data filesystem did not grow with the system APFS partition'

printf 'Verified resized disk: physical=%s, system APFS=%s, recovery=%s, Data=%s bytes\n' \
  "$disk_bytes" "$system_bytes" "$recovery_bytes" "$data_bytes"
