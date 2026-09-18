#!/usr/bin/env bash
set -euo pipefail

test "$(id -un)" = "${GUEST_USERNAME:?}"
test "$HOME" = "/Users/$GUEST_USERNAME"
source "$HOME/.zprofile"

brew cleanup --prune=all
cache=$(brew --cache)
[[ "$cache" == "$HOME/"* && "$cache" != "$HOME/" ]] || exit 1
rm -rf -- "$cache" "$HOME/.rbenv/cache"
npm cache clean --force

rm -f /tmp/Brewfile.base /tmp/Brewfile.xcode /tmp/github_known_hosts \
  /tmp/limit.maxfiles.plist /tmp/tart-guest-agent.plist /tmp/tart-guest-daemon.plist \
  /tmp/macos-image-user-tcc-database.sh
