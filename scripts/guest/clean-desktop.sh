#!/usr/bin/env bash
set -euo pipefail

test "$(id -un)" = "${GUEST_USERNAME:?}"
test "$HOME" = "/Users/$GUEST_USERNAME"
test "$(stat -f %Su /dev/console)" = "$GUEST_USERNAME"
if pgrep -x 'Setup Assistant' >/dev/null; then
  echo 'Complete Setup Assistant before cleaning the desktop' >&2
  exit 1
fi

defaults write NSGlobalDomain NSQuitAlwaysKeepsWindows -bool false
defaults write com.apple.WindowManager StandardHideWidgets -bool true
defaults write com.apple.WindowManager StageManagerHideWidgets -bool true
osascript -l JavaScript <<'JAVASCRIPT'
ObjC.import("AppKit");
var running = $.NSWorkspace.sharedWorkspace.runningApplications;
var applications = [];
var crashReporters = ["com.apple.DiagnosticsReporter", "com.apple.ProblemReporter"];
for (var index = 0; index < running.count; index++) {
    var application = running.objectAtIndex(index);
    var bundleIdentifier = ObjC.unwrap(application.bundleIdentifier);
    if ((Number(application.activationPolicy) === 0 && bundleIdentifier !== "com.apple.finder") ||
        crashReporters.indexOf(bundleIdentifier) !== -1) {
        applications.push(application);
        application.terminate;
    }
}
$.NSRunLoop.currentRunLoop.runUntilDate($.NSDate.dateWithTimeIntervalSinceNow(5));
applications.forEach(function(application) {
    if (!Number(application.terminated)) application.forceTerminate;
});
$.NSRunLoop.currentRunLoop.runUntilDate($.NSDate.dateWithTimeIntervalSinceNow(1));
applications.forEach(function(application) {
    if (!Number(application.terminated)) {
        throw new Error("Could not quit " + ObjC.unwrap(application.localizedName));
    }
});
JAVASCRIPT

defaults -currentHost write com.apple.loginwindow TALAppsToRelaunchAtLogin -array
defaults -currentHost write com.apple.loginwindow TALLogoutSavesState -bool false
saved_state="$HOME/Library/Saved Application State"
if [[ -d "$saved_state" ]]; then
  find "$saved_state" -mindepth 1 -maxdepth 1 -type d -name '*.savedState' -exec rm -rf -- {} +
fi
printf 'Closed desktop applications and cleared login session restoration\n'
