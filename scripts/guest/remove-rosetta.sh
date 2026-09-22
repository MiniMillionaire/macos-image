#!/usr/bin/env bash
set -euo pipefail

paths=(
  /Library/Apple/usr/lib/libRosettaAot.dylib
  /Library/Apple/usr/libexec/oah
  /Library/Apple/usr/share/rosetta
  /var/db/oah
)
for path in "${paths[@]}"; do
  if sudo test -e "$path"; then
    sudo test ! -L "$path"
    sudo rm -rf -- "$path"
  fi
done

sudo pkgutil --forget com.apple.pkg.RosettaUpdateAuto >/dev/null 2>&1 || true
sudo rm -f -- \
  /Library/Apple/System/Library/Receipts/com.apple.pkg.RosettaUpdateAuto.bom \
  /Library/Apple/System/Library/Receipts/com.apple.pkg.RosettaUpdateAuto.plist

for path in "${paths[@]}"; do
  sudo test ! -e "$path"
done
if pkgutil --pkg-info com.apple.pkg.RosettaUpdateAuto >/dev/null 2>&1; then
  echo 'Rosetta package receipt remains installed' >&2
  exit 1
fi
