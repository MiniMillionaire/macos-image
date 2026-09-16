#!/usr/bin/env bash
set -euo pipefail

eval "$(/opt/homebrew/bin/brew shellenv)"
source "$HOME/.zprofile"
selected=$(xcode-select -p)
test "$selected" = "/Applications/Xcode_$XCODE_VERSION.app/Contents/Developer"
xcodebuild -version | grep -Fxq "Xcode $XCODE_VERSION"
for tool in flutter sdkmanager tuist xcodes; do
  command -v "$tool" >/dev/null
done
tuist version
flutter doctor
