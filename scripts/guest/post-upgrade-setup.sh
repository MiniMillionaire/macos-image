#!/usr/bin/env bash
set -euo pipefail

actual_version=$(sw_vers -productVersion)
actual_build=$(sw_vers -buildVersion)
actual_user=$(id -un)
filevault_status=$(sudo -n fdesetup status)
[[ "$actual_version" == "$EXPECTED_VERSION" ]] || { echo "Unexpected macOS version: $actual_version" >&2; exit 1; }
[[ "$actual_build" == "$EXPECTED_BUILD" ]] || { echo "Unexpected macOS build: $actual_build" >&2; exit 1; }
[[ "$actual_user" == "$GUEST_USERNAME" ]] || { echo "Unexpected guest user: $actual_user" >&2; exit 1; }
[[ "$HOME" == "/Users/$GUEST_USERNAME" ]] || { echo "Unexpected guest home: $HOME" >&2; exit 1; }
[[ "$filevault_status" == 'FileVault is Off.' ]] || { echo "Unexpected FileVault status: $filevault_status" >&2; exit 1; }

deadline=$((SECONDS + 120))
while [[ $(stat -f %Su /dev/console) != "$GUEST_USERNAME" ]]; do
  (( SECONDS < deadline )) || { echo 'The upgraded guest did not log in' >&2; exit 1; }
  sleep 5
done

case "$POST_UPGRADE_MODE" in
  observe)
    deadline=$((SECONDS + 360))
    while (( SECONDS < deadline )); do
      if pgrep -x 'Setup Assistant' >/dev/null; then
        declare -F verify_pending_setup >/dev/null || {
          echo "Pending Setup Assistant has no verified mapping for $EXPECTED_VERSION ($EXPECTED_BUILD)" >&2
          exit 1
        }
        verify_pending_setup
        printf 'pending\n'
        exit 0
      fi
      sleep 5
    done
    if declare -F verify_no_pending_setup >/dev/null; then
      verify_no_pending_setup
    fi
    ;;
  verify)
    deadline=$((SECONDS + 120))
    while pgrep -x 'Setup Assistant' >/dev/null; do
      (( SECONDS < deadline )) || { echo 'Post-upgrade Setup Assistant did not finish' >&2; exit 1; }
      sleep 5
    done
    declare -F verify_post_upgrade_setup >/dev/null
    verify_post_upgrade_setup
    ;;
  *) echo "Unknown post-upgrade check: $POST_UPGRADE_MODE" >&2; exit 1 ;;
esac

[[ -e /var/db/.AppleSetupDone ]] || { echo 'Setup Assistant completion marker is missing' >&2; exit 1; }
if pgrep -x 'Setup Assistant' >/dev/null; then
  echo 'Post-upgrade Setup Assistant is still running' >&2
  exit 1
fi
printf 'complete\n'
