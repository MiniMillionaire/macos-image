#!/usr/bin/env bash
set -euo pipefail

test "$(sw_vers -productVersion)" = "$EXPECTED_VERSION"
test "$(sw_vers -buildVersion)" = "$EXPECTED_BUILD"
test "$(uname -m)" = arm64

verify_vanilla() {
  [[ -e /var/db/.AppleSetupDone ]] || { echo 'Setup Assistant is incomplete' >&2; exit 1; }
  ! pgrep -x 'Setup Assistant' >/dev/null || { echo 'Setup Assistant is still running' >&2; exit 1; }
  id "$GUEST_USERNAME" >/dev/null
  real_name=$(dscl . -read "/Users/$GUEST_USERNAME" RealName | sed -E 's/^RealName:[[:space:]]*//; /^[[:space:]]*$/d; s/^[[:space:]]*//')
  [[ "$real_name" == "$GUEST_USERNAME" ]] || { echo "Unexpected full name: $real_name" >&2; exit 1; }
  locale=$(defaults read -g AppleLocale)
  [[ "$locale" == en_US ]] || { echo "Unexpected locale: $locale" >&2; exit 1; }
  languages=$(defaults read -g AppleLanguages | tr -d '[:space:](),"')
  [[ "$languages" == en-US ]] || { echo "Unexpected languages: $languages" >&2; exit 1; }
  keyboard_layout=$(defaults export com.apple.HIToolbox - | plutil -extract AppleEnabledInputSources.0."KeyboardLayout Name" raw -)
  [[ "$keyboard_layout" == 'U.S.' || "$keyboard_layout" == ABC ]] || { echo "Unexpected keyboard layout: $keyboard_layout" >&2; exit 1; }
  timezone=$(readlink /etc/localtime)
  [[ "$timezone" == /var/db/timezone/zoneinfo/GMT ]] || { echo "Unexpected time zone: $timezone" >&2; exit 1; }
  if pgrep -x VoiceOver >/dev/null; then
    echo "VoiceOver is still running" >&2
    exit 1
  fi
  gatekeeper_status=$(spctl --status 2>&1 || true)
  [[ "$gatekeeper_status" == 'assessments disabled' ]] || { echo "Unexpected Gatekeeper status: $gatekeeper_status" >&2; exit 1; }
  console_user=$(stat -f %Su /dev/console)
  console_deadline=$((SECONDS + 120))
  while [[ "$console_user" != "$GUEST_USERNAME" && $SECONDS -lt $console_deadline ]]; do
    sleep 5
    console_user=$(stat -f %Su /dev/console)
  done
  [[ "$console_user" == "$GUEST_USERNAME" ]] || { echo "Automatic login failed: $console_user" >&2; exit 1; }
  developer_dir=$(xcode-select -p)
  test -d "$developer_dir"
  xcrun --find clang
  printf 'Verified macOS %s (%s): user=%s, full name=%s, locale=%s, language=%s, keyboard=%s, timezone=GMT, automatic login=%s, Gatekeeper=%s\n' \
    "$EXPECTED_VERSION" "$EXPECTED_BUILD" "$GUEST_USERNAME" "$real_name" "$locale" "$languages" "$keyboard_layout" "$console_user" "$gatekeeper_status"
  sudo -n true
}

verify_base() {
  source "$HOME/.zprofile"
  guest_agent_path=$(realpath /opt/homebrew/bin/tart-guest-agent)
  test -d /Users/runner
  test -f "$HOME/.ssh/known_hosts"
  test -x "$HOME/actions-runner/run.sh"
  for tool in brew git gh jq node npm pnpm rbenv tart-guest-agent yarn; do
    command -v "$tool" >/dev/null
  done
  csrutil status | grep -F disabled >/dev/null
  sudo launchctl print system/dev.macos-image.tart-guest-daemon >/dev/null
  tcc_query="
    SELECT count(*) FROM access
    WHERE auth_value = 2 AND (
      (service = 'kTCCServiceAccessibility' AND client = '/usr/libexec/sshd-keygen-wrapper') OR
      (service = 'kTCCServiceScreenCapture' AND client = '$guest_agent_path')
    );
  "
  user_tcc=$(bash /tmp/macos-image-user-tcc-database.sh)
  for database in "/Library/Application Support/com.apple.TCC/TCC.db" "$user_tcc"; do
    test "$(sudo sqlite3 "$database" "$tcc_query")" = 2
  done
}

case "$IMAGE_PROFILE" in
  vanilla) verify_vanilla ;;
  sip) csrutil status | grep -F disabled >/dev/null ;;
  base)
    verify_vanilla
    verify_base
    ;;
  xcode)
    verify_vanilla
    verify_base
    test -n "$EXPECTED_XCODE_VERSION"
    test "$(xcode-select -p)" = "/Applications/Xcode_$EXPECTED_XCODE_VERSION.app/Contents/Developer"
    for tool in xcodebuild xcodes flutter sdkmanager tuist; do
      command -v "$tool" >/dev/null
    done
    xcodebuild -version | grep -Fx "Xcode $EXPECTED_XCODE_VERSION"
    tuist version
    flutter doctor
    ;;
  *)
    echo "Unknown image profile: $IMAGE_PROFILE" >&2
    exit 1
    ;;
esac

printf 'Verified image profile: %s\n' "$IMAGE_PROFILE"
boot_session=$(sysctl -n kern.bootsessionuuid)
[[ "$boot_session" =~ ^[0-9A-Fa-f-]{36}$ ]] || { echo 'Missing boot session ID' >&2; exit 1; }
printf 'Boot session: %s\n' "$boot_session"
