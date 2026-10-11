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
    function read(operation, fallback) {
        try { return operation(); }
        catch (error) {
            if (error.errorNumber !== -1728) throw error;
            return fallback;
        }
    }
    const deadline = Date.now() + 120000;
    let previous = '';
    while (Date.now() < deadline) {
        const processes = matches();
        if (processes.length === 1) {
            const pending = processes[0].windows();
            const nodes = [];
            while (pending.length) {
                const element = pending.shift();
                const role = read(() => element.role(), '');
                const labels = [read(() => element.name(), ''), read(() => element.description(), ''),
                    read(() => element.value(), '')].filter(value => typeof value === 'string' && value);
                nodes.push({element, role, labels});
                pending.push(...read(() => element.uiElements(), []));
            }
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
            if (/what[’']s new in xcode/i.test(text)) {
                const button = nodes.find(node => node.role === 'AXButton' && node.labels.includes('Continue'));
                if (button) button.element.click();
            } else if (/welcome to xcode/i.test(text) && !nodes.some(node => node.role === 'AXSheet')) {
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
