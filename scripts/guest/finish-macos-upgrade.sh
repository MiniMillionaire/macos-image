#!/usr/bin/env bash
set -euo pipefail

test "$(sw_vers -productVersion)" = "$EXPECTED_VERSION"
test "$(sw_vers -buildVersion)" = "$EXPECTED_BUILD"
test "$(sudo -n fdesetup status)" = 'FileVault is Off.'
boot_marker=/var/tmp/macos-image-upgrade-boot-session
test "$(cat "$boot_marker")" != "$(sysctl -n kern.bootsessionuuid)"
case "$INSTALLER_APP" in
  '/Applications/Install macOS Sequoia.app') ;;
  *) echo "Unsupported installer cleanup path: $INSTALLER_APP" >&2; exit 1 ;;
esac
if [[ -e "$INSTALLER_APP" ]]; then
  sudo -n rm -rf "$INSTALLER_APP"
fi
rm -f "$boot_marker" /tmp/macos-image-InstallAssistant.pkg /var/tmp/macos-image-start-upgrade.sh
printf 'Verified macOS %s (%s) after upgrade; installer staging removed\n' "$EXPECTED_VERSION" "$EXPECTED_BUILD"
