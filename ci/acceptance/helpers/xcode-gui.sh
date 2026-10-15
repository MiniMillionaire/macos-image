#!/bin/bash
set -euo pipefail
source "$HOME/.zprofile"
configuration=/private/tmp/offline-xcode-config.json
version=$(jq -er .configuration.version "$configuration")
application="/Applications/Xcode_$version.app"
preferences="$HOME/Library/Preferences/com.apple.dt.Xcode.plist"
while IFS= read -r sdk; do
  path=$(xcrun --sdk "$sdk" --show-sdk-path)
  build=$(plutil -extract ProductBuildVersion raw "$path/System/Library/CoreServices/SystemVersion.plist")
  plutil -extract "IDEPlatformsFirstLaunchPresentedSDKVersions-$sdk" json -o - "$preferences" \
    | jq -e --arg build "$build" 'index($build) != null' >/dev/null
  printf 'GUI_PLATFORM=%s SDK_BUILD=%s\n' "$sdk" "$build"
done < <(jq -r '.sdks[].name | select(. == "macosx" or . == "iphoneos" or . == "watchos" or . == "appletvos" or . == "xros")' "$configuration")

finish() {
  status=$?
  trap - EXIT
  screencapture -x /private/tmp/miso-xcode-gui.png || status=1
  osascript -e 'tell application id "com.apple.dt.Xcode" to quit' || status=1
  exit "$status"
}
trap finish EXIT
osascript -l JavaScript - "$application" <<'JAVASCRIPT'
function run(args) {
    const events = Application('System Events');
    const matches = () => events.processes.whose({bundleIdentifier: 'com.apple.dt.Xcode'})();
    if (matches().length) throw new Error('Xcode was already running before GUI acceptance');
    Application(args[0]).activate();
    let stale = false;
    function read(operation, fallback) {
        try { return operation(); }
        catch (error) {
            if (error.errorNumber !== -1728 && error.errorNumber !== -1719) throw error;
            stale = true;
            return fallback;
        }
    }
    const deadline = Date.now() + 120000;
    let previous = '';
    let previousFocus = '';
    let nextWhatsNewAction = 0;
    while (Date.now() < deadline) {
        stale = false;
        const processes = matches();
        if (processes.length === 1) {
            const pending = processes[0].windows().map(window => ({element: window, window}));
            const nodes = [];
            while (pending.length) {
                const {element, window} = pending.shift();
                const role = read(() => element.role(), '');
                const labels = [read(() => element.name(), ''), read(() => element.description(), ''),
                    read(() => element.value(), '')].filter(value => typeof value === 'string' && value);
                nodes.push({element, window, role, labels});
                pending.push(...read(() => element.uiElements(), []).map(element => ({element, window})));
            }
            if (stale) { delay(1); continue; }
            const snapshot = JSON.stringify(nodes.map(({role, labels}) => ({role, labels})));
            if (snapshot !== previous) { console.log(snapshot); previous = snapshot; }
            const text = nodes.flatMap(node => node.labels).join('\n');
            const installButton = nodes.some(node => node.role === 'AXButton' &&
                node.labels.some(label => /^(?:Download(?: & Install)?|Install(?: Now)?|Get)$/i.test(label)));
            if (installButton || /download\s*(?:&|and)\s*install|select (?:the )?(?:components|platforms).*install|install additional components/i.test(text)) {
                throw new Error('Xcode requested component installation on first GUI launch');
            }
            if (nodes.some(node => node.labels.includes('External Agent Access')) &&
                nodes.some(node => node.labels.includes('Control how external coding agents can connect to Xcode'))) {
                console.log('XCODE_GUI_STOP=external-agent-access');
                console.log('XCODE_GUI_FIRST_LAUNCH=passed');
                return;
            }
            const whatsNew = nodes.find(node => node.role === 'AXWindow' &&
                node.labels.some(label => /^what[’']s new in xcode$/i.test(label)));
            if (whatsNew && Date.now() >= nextWhatsNewAction && !nodes.some(node => node.role === 'AXSheet')) {
                const windows = nodes.filter(node => node.role === 'AXWindow');
                const knownWindows = windows.every(node => node === whatsNew ||
                    node.labels.some(label => /^welcome to xcode$/i.test(label)));
                const frontmost = read(() => processes[0].frontmost(), false);
                const focusedWindow = read(() => processes[0].attributes.byName('AXFocusedWindow').value(), null);
                const focused = focusedWindow && /^what[’']s new in xcode$/i.test(read(() => focusedWindow.name(), ''));
                const focus = JSON.stringify({frontmost, focused, knownWindows});
                if (focus !== previousFocus) { console.log('XCODE_GUI_FOCUS=' + focus); previousFocus = focus; }
                const buttons = nodes.filter(node => node.window === whatsNew.element &&
                    node.role === 'AXButton' && read(() => node.element.enabled(), false) &&
                    !read(() => node.element.subrole(), ''));
                const button = buttons.find(node => node.labels.includes('Continue'));
                if (stale) { delay(1); continue; }
                if (knownWindows && !frontmost) {
                    console.log('XCODE_GUI_ACTION=activate-xcode');
                    processes[0].frontmost = true;
                } else if (knownWindows && !focused) {
                    console.log('XCODE_GUI_ACTION=raise-whats-new');
                    read(() => whatsNew.element.actions.byName('AXRaise').perform(), null);
                } else if (knownWindows && button) {
                    console.log('XCODE_GUI_ACTION=continue-whats-new');
                    button.element.click();
                    nextWhatsNewAction = Date.now() + 2000;
                } else if (knownWindows && buttons.length) {
                    console.log('XCODE_GUI_ACTION=return-whats-new');
                    events.keyCode(36);
                    nextWhatsNewAction = Date.now() + 2000;
                }
            } else if (!whatsNew && /welcome to xcode/i.test(text) && !nodes.some(node => node.role === 'AXSheet')) {
                console.log('XCODE_GUI_STOP=welcome');
                console.log('XCODE_GUI_FIRST_LAUNCH=passed');
                return;
            }
        }
        delay(1);
    }
    throw new Error('Xcode did not reach a verified first-launch endpoint within 120 seconds');
}
JAVASCRIPT
