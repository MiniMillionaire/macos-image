#!/usr/bin/env bash
set -euo pipefail

test "$(id -un)" = "${GUEST_USERNAME:?}"
test "$HOME" = "/Users/$GUEST_USERNAME"
sudo -n env GUEST_USERNAME="$GUEST_USERNAME" XCODE_VERSION="${XCODE_VERSION:?}" \
  PYTHONDONTWRITEBYTECODE=1 python3 /tmp/macos-image-slim-xcode.py
rm -f /tmp/macos-image-slim-xcode.py
