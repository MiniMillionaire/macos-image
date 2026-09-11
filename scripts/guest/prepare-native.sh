#!/usr/bin/env bash
set -euo pipefail

test "$(sw_vers -productVersion)" = "$EXPECTED_VERSION"
test "$(sw_vers -buildVersion)" = "$EXPECTED_BUILD"
test "$(id -un)" = "$GUEST_USERNAME"
test -e /var/db/.AppleSetupDone

defaults write -g AppleLocale -string en_US
defaults write -g AppleLanguages -array en-US
input_source='{ InputSourceKind = "Keyboard Layout"; "KeyboardLayout ID" = 0; "KeyboardLayout Name" = "U.S."; }'
defaults write com.apple.HIToolbox AppleEnabledInputSources -array "$input_source"
defaults write com.apple.HIToolbox AppleSelectedInputSources -array "$input_source"
defaults write com.apple.HIToolbox AppleInputSourceHistory -array "$input_source"
defaults write com.apple.HIToolbox AppleCurrentKeyboardLayoutInputSourceID -string com.apple.keylayout.US
defaults write -g AppleKeyboardUIMode -int 3

test "$(defaults read -g AppleLocale)" = en_US
test "$(defaults read -g AppleLanguages | tr -d '[:space:](),\"')" = en-US
test "$(defaults read com.apple.HIToolbox AppleCurrentKeyboardLayoutInputSourceID)" = com.apple.keylayout.US
status=0
output=$(printf '%s\n' "$GUEST_PASSWORD" | sudo -S -p '' spctl --global-disable 2>&1) || status=$?
printf '%s\n' "$output"
if [[ "$status" != 0 ]]; then
  test "$status" = 1
  test "$output" = 'Globally disabling the assessment system needs to be confirmed in System Settings.'
fi
