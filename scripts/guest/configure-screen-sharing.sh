#!/usr/bin/env bash
set -euo pipefail

test "$(id -un)" = "${GUEST_USERNAME:?}"
test -n "${GUEST_PASSWORD:?}"
sudo -n dseditgroup -o edit -a "$GUEST_USERNAME" -t user com.apple.access_screensharing
sudo -n /System/Library/CoreServices/RemoteManagement/ARDAgent.app/Contents/Resources/kickstart \
  -configure -clientopts -setvnclegacy -vnclegacy yes -setvncpw -vncpw "$GUEST_PASSWORD"
sudo -n defaults write /Library/Preferences/com.apple.RemoteManagement ScreenSharingReqPermEnabled -bool false
sudo -n launchctl enable system/com.apple.screensharing
if ! sudo -n launchctl print system/com.apple.screensharing >/dev/null 2>&1; then
  sudo -n launchctl bootstrap system /System/Library/LaunchDaemons/com.apple.screensharing.plist
fi
sudo -n launchctl print system/com.apple.screensharing >/dev/null
