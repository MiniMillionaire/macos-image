#!/usr/bin/env bash
set -euo pipefail

eval "$(/opt/homebrew/bin/brew shellenv)"
source "$HOME/.zprofile"
selected=$(xcode-select -p)
test "$selected" = "/Applications/Xcode_$XCODE_VERSION.app/Contents/Developer"
xcodebuild -version | grep -Fx "Xcode $XCODE_VERSION"
if [[ -n "$XCODE_PLATFORMS" || -n "$XCODE_EXCLUDED_PLATFORMS" ]]; then
  sdks=$(xcodebuild -showsdks)
fi
if [[ -n "$XCODE_PLATFORMS" ]]; then
  IFS=',' read -ra platforms <<< "$XCODE_PLATFORMS"
  for platform in "${platforms[@]}"; do
    case "$platform" in
      iOS) sdk=iphoneos ;;
      watchOS) sdk=watchos ;;
      tvOS) sdk=appletvos ;;
      visionOS) sdk=xros ;;
      *) echo "Unsupported Xcode platform: $platform" >&2; exit 1 ;;
    esac
    xcrun --sdk "$sdk" --show-sdk-path >/dev/null
  done
fi
if [[ -n "$XCODE_EXCLUDED_PLATFORMS" ]]; then
  if [[ "$XCODE_EXCLUDED_PLATFORMS" == *tvOS* ]]; then
    ! grep -Eiq 'tvOS|appletv' <<< "$sdks"
  fi
  if [[ "$XCODE_EXCLUDED_PLATFORMS" == *visionOS* ]]; then
    ! grep -Eiq 'visionOS|xros' <<< "$sdks"
  fi
fi
for tool in flutter sdkmanager tuist xcodes; do
  command -v "$tool" >/dev/null
done
tuist version
flutter doctor
