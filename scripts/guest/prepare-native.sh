#!/usr/bin/env bash
set -euo pipefail

test "$(sw_vers -productVersion)" = "$EXPECTED_VERSION"
test "$(sw_vers -buildVersion)" = "$EXPECTED_BUILD"
test "$(id -un)" = "$GUEST_USERNAME"
test -e /var/db/.AppleSetupDone

echo 'Waiting for the initial language preference migration'
for ((attempt = 0; attempt < 60; attempt++)); do
  schema=$(defaults read -g AppleLanguagesSchemaVersion 2>/dev/null || true)
  [[ "$schema" == 5400 ]] && break
  sleep 2
done
test "$schema" = 5400
test "$(stat -f %Su /dev/console)" = "$GUEST_USERNAME"

defaults write -g AppleLocale -string en_US
defaults write -g AppleLanguages -array en-US
keyboard_preferences=$(mktemp)
trap 'rm -f "$keyboard_preferences"' EXIT
plutil -create xml1 "$keyboard_preferences"
input_source='[{"InputSourceKind":"Keyboard Layout","KeyboardLayout ID":0,"KeyboardLayout Name":"U.S."}]'
for key in AppleEnabledInputSources AppleSelectedInputSources AppleInputSourceHistory; do
  plutil -insert "$key" -json "$input_source" "$keyboard_preferences"
done
plutil -insert AppleCurrentKeyboardLayoutInputSourceID -string com.apple.keylayout.US "$keyboard_preferences"
defaults import com.apple.HIToolbox "$keyboard_preferences"
defaults write -g AppleKeyboardUIMode -int 3

test "$(defaults read -g AppleLocale)" = en_US
test "$(defaults read -g AppleLanguages | tr -d '[:space:](),\"')" = en-US
test "$(defaults read com.apple.HIToolbox AppleCurrentKeyboardLayoutInputSourceID)" = com.apple.keylayout.US
