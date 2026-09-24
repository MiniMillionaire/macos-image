#!/usr/bin/env bash

verify_sequoia_target() {
  test "${EXPECTED_VERSION%%.*}" = 15
  test "${EXPECTED_BUILD#24}" != "$EXPECTED_BUILD"
}

verify_pending_setup() {
  verify_sequoia_target || return 1
  test "$(defaults read com.apple.SetupAssistant MiniBuddyLaunchReason)" = 5 || return 1
  test "$(sudo -n plutil -extract AutoSubmit raw '/Library/Application Support/CrashReporter/DiagnosticMessagesHistory.plist')" = false || return 1
  test "$(sudo -n plutil -extract ThirdPartyDataSubmit raw '/Library/Application Support/CrashReporter/DiagnosticMessagesHistory.plist')" = false || return 1
  local setup_pid pane
  setup_pid=$(pgrep -u "$(id -u)" -x 'Setup Assistant') || return 1
  case "$setup_pid" in ''|*[!0-9]*) return 1 ;; esac
  pane=$(log show --last 10m --style compact --predicate "processIdentifier == $setup_pid AND eventMessage BEGINSWITH 'Making pane visible:'" | tail -n 1) || return 1
  case "$pane" in *'Making pane visible: DiagnosticsAndUsage') ;; *) return 1 ;; esac
}

verify_consent_disabled_or_unset() {
  local key=$1 value
  if value=$(sudo -n plutil -extract "$key" raw '/Library/Application Support/CrashReporter/DiagnosticMessagesHistory.plist' 2>/dev/null); then
    test "$value" = false || {
      printf '%s is unexpectedly enabled\n' "$key" >&2
      return 1
    }
  fi
}

verify_no_pending_setup() {
  verify_sequoia_target
  sudo -n plutil -lint '/Library/Application Support/CrashReporter/DiagnosticMessagesHistory.plist' >/dev/null
  verify_consent_disabled_or_unset AutoSubmit
  verify_consent_disabled_or_unset ThirdPartyDataSubmit
}

verify_post_upgrade_setup() {
  verify_sequoia_target || return 1
  test "$(defaults read com.apple.SetupAssistant LastSeenDiagnosticsProductVersion)" = "$EXPECTED_VERSION" || return 1
  test "$(defaults read com.apple.SetupAssistant MiniBuddyLaunchReason)" = 0 || return 1
  test "$(defaults read com.apple.SetupAssistant selectedFDEEscrowType)" = DeclinedFDE || return 1
  test "$(sudo -n plutil -extract AutoSubmit raw '/Library/Application Support/CrashReporter/DiagnosticMessagesHistory.plist')" = false || return 1
  test "$(sudo -n plutil -extract ThirdPartyDataSubmit raw '/Library/Application Support/CrashReporter/DiagnosticMessagesHistory.plist')" = false || return 1
  test "$(sudo -n plutil -extract AutoSubmitVersion raw '/Library/Application Support/CrashReporter/DiagnosticMessagesHistory.plist')" = 18 || return 1
}

verify_running_post_upgrade_setup() {
  test "$EXPECTED_VERSION" = 15.7.7 || return 1
  test "$EXPECTED_BUILD" = 24G720 || return 1
  verify_post_upgrade_setup
}
