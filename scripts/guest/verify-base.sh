#!/usr/bin/env bash
set -euo pipefail

source "$HOME/.zprofile"
test -d /Users/runner
test -f "$HOME/.ssh/known_hosts"
test -x "$HOME/actions-runner/run.sh"
for tool in brew git gh jq node npm pnpm rbenv tart-guest-agent yarn; do
  command -v "$tool" >/dev/null
done
csrutil status | grep -Fq disabled
