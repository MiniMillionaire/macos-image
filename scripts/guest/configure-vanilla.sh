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
defaults write com.apple.Accessibility AccessibilityEnabled -bool false
defaults write com.apple.Accessibility ApplicationAccessibilityEnabled -bool false
defaults write com.apple.universalaccess voiceOverOnOffKey -bool false
killall VoiceOver 2>/dev/null || true
sudo systemsetup -settimezone GMT >/dev/null 2>&1
sudo systemsetup -setsleep Off >/dev/null 2>&1
sudo systemsetup -setcomputersleep Off >/dev/null 2>&1
gatekeeper_status=$(spctl --status 2>&1 || true)
[[ "$gatekeeper_status" == 'assessments disabled' ]]
