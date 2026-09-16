#!/usr/bin/env bash
set -euo pipefail

eval "$(/opt/homebrew/bin/brew shellenv)"
source "$HOME/.zprofile"
selected=$(xcode-select -p)
test "$selected" = "/Applications/Xcode_$XCODE_VERSION.app/Contents/Developer"
xcodebuild -version | grep -Fxq "Xcode $XCODE_VERSION"
command -v flutter sdkmanager xcodes >/dev/null
flutter doctor
