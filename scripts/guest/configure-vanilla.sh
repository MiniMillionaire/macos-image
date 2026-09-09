#!/usr/bin/env bash
set -euo pipefail

actual_version=$(sw_vers -productVersion)
actual_build=$(sw_vers -buildVersion)

[[ "$actual_version" == "$EXPECTED_VERSION" ]]
[[ "$actual_build" == "$EXPECTED_BUILD" ]]

printf '%s\n' "$GUEST_PASSWORD" | sudo -S install -d -m 0755 /etc/sudoers.d
printf '%s ALL=(ALL) NOPASSWD: ALL\n' "$GUEST_USERNAME" | sudo tee /etc/sudoers.d/ci-user >/dev/null
sudo chmod 0440 /etc/sudoers.d/ci-user
sudo visudo -cf /etc/sudoers.d/ci-user

if [[ "$GUEST_USERNAME" == admin && "$GUEST_PASSWORD" == admin ]]; then
  echo '00000000: 1ced 3f4a bcbc ba2c caca 4e82' | sudo xxd -r - /etc/kcpassword
  sudo defaults write /Library/Preferences/com.apple.loginwindow autoLoginUser "$GUEST_USERNAME"
fi

sudo defaults write /Library/Preferences/com.apple.screensaver loginWindowIdleTime 0
defaults -currentHost write com.apple.screensaver idleTime 0
sudo systemsetup -setsleep Off >/dev/null
sudo systemsetup -setcomputersleep Off >/dev/null
sudo sysadminctl -screenLock off -password "$GUEST_PASSWORD"
spctl --status | grep -Fq 'assessments disabled'

