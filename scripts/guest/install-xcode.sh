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

xcodebuild -downloadAllPlatforms

if [[ -n "$XCODE_COMPONENTS" ]]; then
  IFS=',' read -ra components <<< "$XCODE_COMPONENTS"
  for component in "${components[@]}"; do
    xcodebuild -downloadComponent "$component"
  done
fi
