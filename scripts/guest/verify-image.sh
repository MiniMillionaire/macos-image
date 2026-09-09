#!/usr/bin/env bash
set -euo pipefail

[[ $(sw_vers -productVersion) == "$EXPECTED_VERSION" ]]
[[ $(uname -m) == arm64 ]]

case "$IMAGE_PROFILE" in
  vanilla)
    id admin >/dev/null
    ;;
  base)
    eval "$(/opt/homebrew/bin/brew shellenv)"
    command -v brew git gh jq node tart-guest-agent >/dev/null
    test -x "$HOME/actions-runner/run.sh"
    ;;
  xcode)
    eval "$(/opt/homebrew/bin/brew shellenv)"
    command -v xcodebuild xcodes flutter sdkmanager >/dev/null
    xcodebuild -version
    flutter doctor
    ;;
  *)
    echo "Unknown image profile: $IMAGE_PROFILE" >&2
    exit 1
    ;;
esac
