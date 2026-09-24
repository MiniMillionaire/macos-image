#!/usr/bin/env bash
set -euo pipefail

boot_marker="$HOME/.macos-image-upgrade-boot-session"
previous_boot=$(cat "$boot_marker")
current_boot=$(sysctl -n kern.bootsessionuuid)

test "$(sw_vers -productVersion)" = "$EXPECTED_VERSION"
test "$(sw_vers -buildVersion)" = "$EXPECTED_BUILD"
test "$(sudo -n fdesetup status)" = 'FileVault is Off.'
test -n "$previous_boot"
test "$previous_boot" != "$current_boot"

rm -f "$boot_marker" /var/tmp/macos-image-software-update.sh
printf 'Verified macOS %s (%s) after software update\n' "$EXPECTED_VERSION" "$EXPECTED_BUILD"
