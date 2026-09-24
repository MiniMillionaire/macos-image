#!/usr/bin/env bash
set -euo pipefail

boot_marker="$HOME/.macos-image-upgrade-boot-session"
update_label="macOS $UPDATE_TITLE $EXPECTED_VERSION-$EXPECTED_BUILD"

test "$(sw_vers -productVersion)" = "$SOURCE_VERSION"
test "$(sw_vers -buildVersion)" = "$SOURCE_BUILD"
test "$(sudo -n fdesetup status)" = 'FileVault is Off.'
test ! -e "$boot_marker"

scan=$(softwareupdate --list 2>&1)
printf '%s\n' "$scan"
matches=$(printf '%s\n' "$scan" |
  sed -n 's/^[[:space:]*-]*Label: //p' |
  grep -Fxc "$update_label" || true)
test "$matches" = 1

sysctl -n kern.bootsessionuuid > "$boot_marker"
printf 'Selected software update: %s\n' "$update_label"
