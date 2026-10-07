#!/bin/bash
set -euo pipefail
export PATH=/usr/bin:/bin:/usr/sbin:/sbin
proof="$HOME/Documents/base-tcc-control.txt"
test ! -e "$proof"
printf 'offline-base-before\n' > "$proof"
open -a TextEdit "$proof"
printf 'TCC_STEP=opened\n'
osascript <<'APPLESCRIPT'
with timeout of 15 seconds
    tell application "System Events"
        repeat 40 times
            if exists window "base-tcc-control.txt" of process "TextEdit" then exit repeat
            delay 0.25
        end repeat
        if not (exists window "base-tcc-control.txt" of process "TextEdit") then error "Document window is absent"
        set frontmost of process "TextEdit" to true
        key code 53
        delay 0.5
    end tell
end timeout
APPLESCRIPT
printf 'TCC_STEP=focused\n'
osascript -e 'with timeout of 15 seconds' -e 'tell application "System Events" to keystroke "a" using command down' -e 'end timeout'
sleep 0.5
printf 'TCC_STEP=selected\n'
osascript <<'APPLESCRIPT'
with timeout of 15 seconds
    tell application "System Events"
        repeat with characterValue in characters of "offline-base-ui-input-passed"
            keystroke (characterValue as text)
            delay 0.06
        end repeat
    end tell
end timeout
APPLESCRIPT
printf 'TCC_STEP=typed\n'
sleep 0.5
osascript -e 'with timeout of 15 seconds' -e 'tell application "System Events" to keystroke "s" using command down' -e 'end timeout'
printf 'TCC_STEP=save-requested\n'
for attempt in {1..40}; do
    if [[ "$(tr -d '\r\n' < "$proof")" == offline-base-ui-input-passed ]]; then break; fi
    sleep 0.25
done
test "$(tr -d '\r\n' < "$proof")" = offline-base-ui-input-passed
printf 'TCC_UI_SAVED_TEXT=passed\n'
screencapture -x /private/tmp/base-tcc-screen.png
test "$(stat -f %z /private/tmp/base-tcc-screen.png)" -gt 10000
sips -g pixelWidth -g pixelHeight /private/tmp/base-tcc-screen.png
printf 'TCC_SCREEN_CAPTURE_FILE=passed\n'
