#!/bin/bash
set -euo pipefail
source=${1:?Tart source directory required}
manifest=${2:?Native source manifest required}
output=${3:?New output directory required}
[[ $(id -u) == 0 ]] || exit 1
[[ ! -e "$output" ]] || exit 1
[[ -f "$source/disk.img" && ! -L "$source/disk.img" ]] || exit 1
[[ -f "$source/nvram.bin" && ! -L "$source/nvram.bin" ]] || exit 1
[[ -f "$source/config.json" && ! -L "$source/config.json" ]] || exit 1

resize_tart=${4:?Recovery-aware Tart executable required}
disk_bytes=${5:?Target disk size required}
importer=${6:?Native manifest importer required}
[[ "$disk_bytes" =~ ^[0-9]+$ && "$disk_bytes" -ge 64000000000 &&
  "$disk_bytes" -le 2000000000000 && $((disk_bytes % 1000000000)) == 0 ]] || exit 1
disk_gb=$((disk_bytes / 1000000000))
[[ -x "$resize_tart" ]] || exit 1
"$resize_tart" set --help | /usr/bin/grep -q -- '--relocate-recovery'
mkdir "$output"
export TART_HOME="$output/tart"
export TART_NO_AUTO_PRUNE=1
vm="$TART_HOME/vms/construction"
mkdir -p "$vm"
for name in config.json nvram.bin disk.img; do cp -c "$source/$name" "$vm/$name"; done
"$resize_tart" get construction --format json > "$output/before.json"
/usr/bin/jq -e '.State == "stopped" and .DiskFormat == "raw"' "$output/before.json" >/dev/null
/usr/bin/perl -e 'alarm 1800; exec @ARGV' "$resize_tart" set construction --disk-size "$disk_gb" --relocate-recovery > "$output/grow-gpt.log" 2>&1
[[ $(stat -f %z "$vm/disk.img") == "$disk_bytes" ]] || exit 1
whole=
finish() {
  result=$?
  trap - EXIT
  if [[ -n "$whole" ]]; then hdiutil detach "$whole" >> "$output/detach.log" 2>&1 || result=1; fi
  printf '%s\n' "$result" > "$output/exit-status"
  exit "$result"
}
trap finish EXIT
hdiutil attach -nomount -nobrowse -noautofsck -owners on -readwrite -plist "$vm/disk.img" > "$output/attach.plist"
plutil -convert json -o "$output/attach.json" "$output/attach.plist"
whole=$(/usr/bin/jq -er '[."system-entities"[] | select(."content-hint" == "GUID_partition_scheme") | ."dev-entry"] | if length == 1 then .[0] else error("Ambiguous disk") end' "$output/attach.json")
[[ "$whole" =~ ^/dev/disk[0-9]+$ ]] || exit 1
diskutil apfs list -plist > "$output/apfs-before.plist"
plutil -convert json -o "$output/apfs-before.json" "$output/apfs-before.plist"
main=$(/usr/bin/jq -er --arg store "${whole#/dev/}s2" '[.Containers[] | select(any(.PhysicalStores[]; .DeviceIdentifier == $store)) | .ContainerReference] | if length == 1 then .[0] else error("Ambiguous main container") end' "$output/apfs-before.json")
[[ "$main" =~ ^disk[0-9]+$ ]] || exit 1
/usr/bin/perl -e 'alarm 900; exec @ARGV' diskutil apfs resizeContainer "$main" 0 > "$output/grow-apfs.log" 2>&1
diskutil unmountDisk "$whole" > "$output/unmount.log" 2>&1
for partition in 1 2 3; do
  /usr/bin/perl -e 'alarm 900; exec @ARGV' /sbin/fsck_apfs -n "/dev/r${whole#/dev/}s$partition" > "$output/fsck-$partition.log" 2>&1
done
hdiutil detach "$whole" > "$output/detach.log" 2>&1
whole=
"$importer" "$vm" "$manifest" "$output/bundle" > "$output/import.log" 2>&1
