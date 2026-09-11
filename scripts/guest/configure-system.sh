#!/usr/bin/env bash
set -euo pipefail

actual_version=$(sw_vers -productVersion)
test "$actual_version" = "$EXPECTED_VERSION"

append_line() {
  local line=$1
  local file=$2
  grep -Fqx "$line" "$file" 2>/dev/null || printf '%s\n' "$line" >> "$file"
}

touch "$HOME/.zprofile"
[[ -e "$HOME/.profile" ]] || ln -s "$HOME/.zprofile" "$HOME/.profile"
append_line 'export LANG=en_US.UTF-8' "$HOME/.zprofile"
append_line 'eval "$(/opt/homebrew/bin/brew shellenv)"' "$HOME/.zprofile"
append_line 'export HOMEBREW_NO_AUTO_UPDATE=1' "$HOME/.zprofile"
append_line 'export HOMEBREW_NO_INSTALL_CLEANUP=1' "$HOME/.zprofile"

sudo install -o root -g wheel -m 0644 /tmp/limit.maxfiles.plist /Library/LaunchDaemons/limit.maxfiles.plist
sudo mdutil -a -i off
sudo systemsetup -setsleep Off >/dev/null
sudo systemsetup -setcomputersleep Off >/dev/null
sudo tmutil disable || true

mkdir -p "$HOME/.ssh"
install -m 0600 /tmp/github_known_hosts "$HOME/.ssh/known_hosts"

