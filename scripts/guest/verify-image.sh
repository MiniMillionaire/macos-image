#!/usr/bin/env bash
set -euo pipefail

[[ $(sw_vers -productVersion) == "$EXPECTED_VERSION" ]]
[[ $(sw_vers -buildVersion) == "$EXPECTED_BUILD" ]]
[[ $(uname -m) == arm64 ]]

case "$IMAGE_PROFILE" in
  vanilla)
    id "$GUEST_USERNAME" >/dev/null
    real_name=$(dscl . -read "/Users/$GUEST_USERNAME" RealName | sed -E 's/^RealName:[[:space:]]*//; /^[[:space:]]*$/d; s/^[[:space:]]*//')
    [[ "$real_name" == "$GUEST_USERNAME" ]] || { echo "Unexpected full name: $real_name" >&2; exit 1; }
    locale=$(defaults read -g AppleLocale)
    [[ "$locale" == en_US ]] || { echo "Unexpected locale: $locale" >&2; exit 1; }
    languages=$(defaults read -g AppleLanguages | tr -d '[:space:](),"')
    [[ "$languages" == en-US ]] || { echo "Unexpected languages: $languages" >&2; exit 1; }
    keyboard_layout=$(defaults export com.apple.HIToolbox - | plutil -extract AppleEnabledInputSources.0."KeyboardLayout Name" raw -)
    [[ "$keyboard_layout" == 'U.S.' ]] || { echo "Unexpected keyboard layout: $keyboard_layout" >&2; exit 1; }
    timezone=$(readlink /etc/localtime)
    [[ "$timezone" == /var/db/timezone/zoneinfo/UTC ]] || { echo "Unexpected time zone: $timezone" >&2; exit 1; }
    if pgrep -x VoiceOver >/dev/null; then
      echo "VoiceOver is still running" >&2
      exit 1
    fi
    gatekeeper_status=$(spctl --status 2>&1 || true)
    [[ "$gatekeeper_status" == 'assessments disabled' ]] || { echo "Unexpected Gatekeeper status: $gatekeeper_status" >&2; exit 1; }
    ;;
  sip)
    csrutil status | grep -Fq disabled
    ;;
  base)
    eval "$(/opt/homebrew/bin/brew shellenv)"
    guest_agent_path=$(realpath /opt/homebrew/bin/tart-guest-agent)
    test -d /Users/runner
    test -f "$HOME/.ssh/known_hosts"
    test -x "$HOME/actions-runner/run.sh"
    command -v brew git gh jq node npm pnpm rbenv tart-guest-agent yarn >/dev/null
    csrutil status | grep -Fq disabled
    sudo launchctl print system/dev.macos-image.tart-guest-daemon >/dev/null
    tcc_query="
      SELECT count(*) FROM access
      WHERE auth_value = 2 AND (
        (service = 'kTCCServiceAccessibility' AND client = '/usr/libexec/sshd-keygen-wrapper') OR
        (service = 'kTCCServiceScreenCapture' AND client = '$guest_agent_path')
      );
    "
    for database in "/Library/Application Support/com.apple.TCC/TCC.db" "$HOME/Library/Application Support/com.apple.TCC/TCC.db"; do
      [[ $(sudo sqlite3 "$database" "$tcc_query") == 2 ]]
    done
    ;;
  xcode)
    eval "$(/opt/homebrew/bin/brew shellenv)"
    command -v xcodebuild xcodes flutter sdkmanager >/dev/null
    xcodebuild -version
    flutter doctor
    ;;
  *)
    echo "Unknown image profile: $IMAGE_PROFILE" >&2
    exit 1
    ;;
esac
