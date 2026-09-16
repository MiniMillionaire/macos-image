#!/usr/bin/env bash
set -euo pipefail

eval "$(/opt/homebrew/bin/brew shellenv)"
eval "$(rbenv init - bash)"
android_home="$HOME/android-sdk"
flutter_home="$HOME/flutter"

append_line() {
  local line=$1
  grep -Fqx "$line" "$HOME/.zprofile" 2>/dev/null || printf '%s\n' "$line" >> "$HOME/.zprofile"
}

brew install openjdk@17
append_line 'export PATH="/opt/homebrew/opt/openjdk@17/bin:$PATH"'
append_line 'export ANDROID_HOME="$HOME/android-sdk"'
append_line 'export ANDROID_SDK_ROOT="$ANDROID_HOME"'
append_line 'export PATH="$PATH:$ANDROID_HOME/cmdline-tools/latest/bin:$ANDROID_HOME/platform-tools:$ANDROID_HOME/emulator"'
append_line 'export FLUTTER_HOME="$HOME/flutter"'
append_line 'export PATH="$FLUTTER_HOME/bin:$FLUTTER_HOME/bin/cache/dart-sdk/bin:$PATH"'

export PATH="/opt/homebrew/opt/openjdk@17/bin:$PATH"
export ANDROID_HOME="$android_home"
export ANDROID_SDK_ROOT="$android_home"
export PATH="$PATH:$android_home/cmdline-tools/latest/bin:$android_home/platform-tools:$android_home/emulator"

if [[ ! -x "$android_home/cmdline-tools/latest/bin/sdkmanager" ]]; then
  archive=$(mktemp)
  curl -fsSL "https://dl.google.com/android/repository/commandlinetools-mac-14742923_latest.zip" -o "$archive"
  mkdir -p "$android_home/cmdline-tools"
  unzip -q "$archive" -d "$android_home/cmdline-tools"
  mv "$android_home/cmdline-tools/cmdline-tools" "$android_home/cmdline-tools/latest"
  rm -f "$archive"
fi

yes | sdkmanager --licenses >/dev/null || true
sdkmanager 'platform-tools' 'platforms;android-36' 'build-tools;36.0.0' 'ndk;28.2.13676358'

if [[ ! -d "$flutter_home/.git" ]]; then
  git clone https://github.com/flutter/flutter.git "$flutter_home"
fi

git -C "$flutter_home" fetch --tags origin stable
git -C "$flutter_home" checkout stable
git -C "$flutter_home" pull --ff-only origin stable
export PATH="$flutter_home/bin:$flutter_home/bin/cache/dart-sdk/bin:$PATH"
flutter precache
flutter doctor --android-licenses
flutter doctor

gem update --system
gem install bundler cocoapods fastlane xcpretty
