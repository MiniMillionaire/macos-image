#!/usr/bin/env bash
set -euo pipefail

eval "$(/opt/homebrew/bin/brew shellenv)"
download_url=$(curl -fsSL https://api.github.com/repos/actions/runner/releases/latest | jq -r '.assets[] | select(.name | test("actions-runner-osx-arm64-[0-9.]+.tar.gz")) | .browser_download_url')
test -n "$download_url"
test "$download_url" != null

rm -rf "$HOME/actions-runner"
mkdir -p "$HOME/actions-runner"
curl -fsSL "$download_url" | tar -xz -C "$HOME/actions-runner"
sudo ln -sfn "/Users/$GUEST_USERNAME" /Users/runner

