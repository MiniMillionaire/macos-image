#!/usr/bin/env bash
set -euo pipefail

source "$HOME/.zprofile"
test -d /Users/runner
test -f "$HOME/.ssh/known_hosts"
test -x "$HOME/actions-runner/run.sh"
command -v brew git gh jq node npm pnpm rbenv tart-guest-agent yarn >/dev/null
csrutil status | grep -Fq disabled
