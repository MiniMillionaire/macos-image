#!/usr/bin/env bash
set -euo pipefail

if xcode-select -p >/dev/null 2>&1; then
  exit 0
fi

marker=/tmp/.com.apple.dt.CommandLineTools.installondemand.in-progress
touch "$marker"
trap 'rm -f "$marker"' EXIT
label=$(softwareupdate --list 2>&1 | sed -n 's/.*Label: \(Command Line Tools for Xcode-.*\)/\1/p' | tail -1)
[[ -n "$label" ]]
sudo softwareupdate --install "$label"
xcode-select -p
