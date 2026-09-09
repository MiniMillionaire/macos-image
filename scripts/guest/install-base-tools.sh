#!/usr/bin/env bash
set -euo pipefail

if ! command -v brew >/dev/null; then
  NONINTERACTIVE=1 /bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"
fi

eval "$(/opt/homebrew/bin/brew shellenv)"
brew update
brew bundle --file=/tmp/Brewfile.base
git lfs install
sudo softwareupdate --install-rosetta --agree-to-license

if ! rbenv versions --bare | grep -Fxq 2.7.8; then
  rbenv install 2.7.8
fi

latest_ruby=$(rbenv install -l | grep -Ev '[-a-z]' | tail -1)
if ! rbenv versions --bare | grep -Fxq "$latest_ruby"; then
  rbenv install "$latest_ruby"
fi
rbenv global "$latest_ruby"
eval "$(rbenv init - bash)"
gem install bundler

grep -Fqx 'eval "$(rbenv init - zsh)"' "$HOME/.zprofile" || printf '%s\n' 'eval "$(rbenv init - zsh)"' >> "$HOME/.zprofile"
grep -Fqx 'export PATH="/opt/homebrew/opt/node@24/bin:$PATH"' "$HOME/.zprofile" || printf '%s\n' 'export PATH="/opt/homebrew/opt/node@24/bin:$PATH"' >> "$HOME/.zprofile"
export PATH="/opt/homebrew/opt/node@24/bin:$PATH"
npm install --global yarn pnpm

sudo install -o root -g wheel -m 0644 /tmp/tart-guest-daemon.plist /Library/LaunchDaemons/dev.macos-image.tart-guest-daemon.plist
sudo install -o root -g wheel -m 0644 /tmp/tart-guest-agent.plist /Library/LaunchAgents/dev.macos-image.tart-guest-agent.plist

