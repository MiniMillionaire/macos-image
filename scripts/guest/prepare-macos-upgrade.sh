#!/usr/bin/env bash
set -euo pipefail

archive=/tmp/macos-image-InstallAssistant.pkg
boot_marker="$HOME/.macos-image-upgrade-boot-session"
test ! -e "$boot_marker"
test ! -e "$boot_marker"
test "$(sudo -n fdesetup status)" = 'FileVault is Off.'
signature=$(pkgutil --check-signature "$archive")
printf '%s\n' "$signature"
grep -F 'Status: signed Apple Software' <<< "$signature" >/dev/null
sudo -n installer -pkg "$archive" -target /
rm -f "$archive"

mount_dir=$(mktemp -d /tmp/macos-image-installer.XXXXXX)
mounted=false
cleanup() {
  if [[ "$mounted" == true ]]; then
    hdiutil detach "$mount_dir" -quiet
  fi
  rmdir "$mount_dir"
}
trap cleanup EXIT
hdiutil attach "$INSTALLER_APP/Contents/SharedSupport/SharedSupport.dmg" \
  -readonly -nobrowse -mountpoint "$mount_dir" -quiet
mounted=true
manifests=0
while IFS= read -r manifest; do
  version=$(plutil -extract OSVersion raw "$manifest" 2>/dev/null) || continue
  build=$(plutil -extract Build raw "$manifest")
  test "$version" = "$EXPECTED_VERSION"
  test "$build" = "$EXPECTED_BUILD"
  manifests=$((manifests + 1))
done < <(find "$mount_dir" -type f -name '*.json')
test "$manifests" -gt 0
printf 'Verified %s installer manifests for macOS %s (%s)\n' "$manifests" "$EXPECTED_VERSION" "$EXPECTED_BUILD"
cleanup
trap - EXIT
sysctl -n kern.bootsessionuuid > "$boot_marker"
