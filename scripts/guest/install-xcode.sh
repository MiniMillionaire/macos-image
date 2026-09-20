#!/usr/bin/env bash
set -euo pipefail

eval "$(/opt/homebrew/bin/brew shellenv)"
brew update
brew upgrade
brew install xcodes

archive="/Users/$GUEST_USERNAME/Downloads/Xcode_$XCODE_VERSION.xip"
target="/Applications/Xcode_$XCODE_VERSION.app"

if [[ ! -d "$target" ]]; then
  sudo xcodes install "$XCODE_VERSION" --experimental-unxip --path "$archive" --select --empty-trash
  selected=$(xcode-select -p)
  installed=${selected%/Contents/Developer}
  sudo mv "$installed" "$target"
fi

rm -f "$archive"
sudo xcode-select --switch "$target"
sudo xcodebuild -license accept
xcodebuild -runFirstLaunch

brew bundle --file=/tmp/Brewfile.xcode
mise use --global --pin tuist@latest
grep -Fqx 'export PATH="$HOME/.local/share/mise/shims:$PATH"' "$HOME/.zprofile" ||
  printf '%s\n' 'export PATH="$HOME/.local/share/mise/shims:$PATH"' >> "$HOME/.zprofile"
export PATH="$HOME/.local/share/mise/shims:$PATH"
tuist version

runtime_directory=$(mktemp -d "$HOME/Downloads/macos-image-runtimes.XXXXXX")
download_runtime() {
  if [[ -n "$XCODE_PLATFORM_ARCHITECTURE" ]]; then
    xcodebuild "$@" -exportPath "$runtime_directory" -architectureVariant "$XCODE_PLATFORM_ARCHITECTURE"
  else
    xcodebuild "$@" -exportPath "$runtime_directory"
  fi
}
if [[ -n "$XCODE_PLATFORMS" ]]; then
  IFS=',' read -ra platforms <<< "$XCODE_PLATFORMS"
  for platform in "${platforms[@]}"; do
    download_runtime -downloadPlatform "$platform"
  done
else
  download_runtime -downloadAllPlatforms
fi
runtime_count=0
while IFS= read -r -d '' runtime; do
  xcodebuild -importPlatform "$runtime"
  rm -f "$runtime"
  runtime_count=$((runtime_count + 1))
done < <(find "$runtime_directory" -type f -name '*.dmg' -print0)
test "$runtime_count" -gt 0
rm -rf "$runtime_directory"

if [[ -n "$XCODE_EXCLUDED_PLATFORMS" ]]; then
  IFS=',' read -ra excluded_platforms <<< "$XCODE_EXCLUDED_PLATFORMS"
  for platform in "${excluded_platforms[@]}"; do
    case "$platform" in
      tvOS) bundles=(AppleTVOS.platform AppleTVSimulator.platform) ;;
      visionOS) bundles=(XROS.platform XRSimulator.platform) ;;
      *) echo "Unsupported excluded Xcode platform: $platform" >&2; exit 1 ;;
    esac
    for bundle in "${bundles[@]}"; do
      sudo rm -rf -- "$target/Contents/Developer/Platforms/$bundle"
    done
  done
fi

if [[ -n "$XCODE_COMPONENTS" ]]; then
  IFS=',' read -ra components <<< "$XCODE_COMPONENTS"
  for component in "${components[@]}"; do
    xcodebuild -downloadComponent "$component"
  done
fi
