#!/usr/bin/env bash
set -euo pipefail

die() {
  echo "$*" >&2
  exit 1
}

[[ ${TARGET_DISK_SIZE_GB:-} =~ ^[1-9][0-9]*$ ]] || die 'Invalid target disk size'

plist_value() {
  printf '%s\n' "$disk_plist" | plutil -extract "$1" raw -
}

prefix=AllDisksAndPartitions.0
target_bytes=$((TARGET_DISK_SIZE_GB * 1000000000))

read_layout() {
  disk_plist=$(diskutil list -plist physical 2>/dev/null || true)
  disk_bytes=$(plist_value "$prefix.Size" 2>/dev/null || true)
  isc_bytes=$(plist_value "$prefix.Partitions.0.Size" 2>/dev/null || true)
  system_bytes=$(plist_value "$prefix.Partitions.1.Size" 2>/dev/null || true)
  recovery_bytes=$(plist_value "$prefix.Partitions.2.Size" 2>/dev/null || true)
  data_kib=$(df -k /System/Volumes/Data 2>/dev/null | awk 'NR == 2 { print $2 }' || true)
}

resize_complete() {
  if [[ $disk_bytes =~ ^[1-9][0-9]*$ && $isc_bytes =~ ^[1-9][0-9]*$ &&
        $system_bytes =~ ^[1-9][0-9]*$ && $recovery_bytes =~ ^[1-9][0-9]*$ &&
        $data_kib =~ ^[1-9][0-9]*$ ]]; then
    data_bytes=$((data_kib * 1024))
    gap_bytes=$((disk_bytes - isc_bytes - system_bytes - recovery_bytes))
    [[ $(plist_value "$prefix.Partitions.0.Content") == Apple_APFS_ISC &&
       $(plist_value "$prefix.Partitions.1.Content") == Apple_APFS &&
       $(plist_value "$prefix.Partitions.2.Content") == Apple_APFS_Recovery ]] || return 1
    ! plist_value "$prefix.Partitions.3.Size" >/dev/null 2>&1 || return 1
    (( disk_bytes == target_bytes && gap_bytes >= 0 && gap_bytes <= 1048576 &&
       data_bytes >= system_bytes - 67108864 && data_bytes <= system_bytes ))
    return
  fi
  return 1
}

for _ in {1..60}; do
  read_layout
  if resize_complete; then
    printf 'Verified resized disk: physical=%s, system APFS=%s, recovery=%s, Data=%s bytes\n' \
      "$disk_bytes" "$system_bytes" "$recovery_bytes" "$data_bytes"
    exit 0
  fi
  sleep 5
done

die 'Guest filesystem did not reach the requested size'
