const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const vm = require('node:vm');

const shell = fs.readFileSync(path.join(__dirname, '../helpers/xcode-gui.sh'), 'utf8');
const code = shell.split("<<'JAVASCRIPT'\n")[1].split('\nJAVASCRIPT')[0];

function node(role, name, children = [], options = {}) {
    return {
        role: () => role, name: () => name, description: () => '', value: () => '',
        uiElements: () => children, enabled: () => options.enabled ?? true,
        subrole: () => options.subrole ?? null, click: options.click ?? (() => {})
    };
}

function check(makeWindows, expected, expectedClicks = 0, frontmost = true) {
    let launched = false, elapsed = 0, clicks = 0;
    const messages = [];
    const welcome = node('AXWindow', 'Welcome to Xcode');
    const click = () => { clicks++; };
    const context = vm.createContext({
        Application: name => name === 'System Events'
            ? {processes: {whose: () => () => launched
                ? [{windows: () => makeWindows({welcome, click, clicks}), frontmost: () => frontmost}] : []},
                keyCode: key => { assert.equal(key, 36); click(); }}
            : {activate: () => { launched = true; }},
        Date: {now: () => elapsed}, delay: () => { elapsed += 1000; },
        console: {log: line => messages.push(line)}
    });
    vm.runInContext(code, context);
    if (expected instanceof RegExp) assert.throws(() => context.run(['/Applications/Xcode.app']), expected);
    else {
        context.run(['/Applications/Xcode.app']);
        assert(messages.includes(`XCODE_GUI_STOP=${expected}`));
        assert(messages.includes('XCODE_GUI_FIRST_LAUNCH=passed'));
    }
    assert.equal(clicks, expectedClicks);
}

const button = (name, click, options = {}) => node('AXButton', name, [], {click, ...options});
const news = children => node('AXWindow', 'What’s New in Xcode', children);
const timeout = /within 120 seconds/;
const install = /requested component installation/;

check(({welcome}) => [welcome], 'welcome');
check(() => [], timeout);
check(({welcome}) => [welcome, node('AXSheet', 'Unknown modal')], timeout);
check(({welcome, click}) => [welcome, button('Download', click)], install);
check(({welcome, click, clicks}) => clicks ? [welcome] : [news([button('Continue', click)])], 'welcome', 1);
check(({welcome, click, clicks}) => clicks ? [welcome] : [news([
    button('close button', click, {subrole: 'AXCloseButton'}),
    button('zoom button', click, {subrole: 'AXZoomButton'}),
    button('minimize button', click, {subrole: 'AXMinimizeButton'}),
    button('', click), button('', click), button('', click),
    node('AXStaticText', 'External Agent Access')
])], 'welcome', 1);
check(({click}) => [news([button('', click), button('', click)])], timeout, 1);
check(({click}) => [news([button('', click, {enabled: false})])], timeout);
check(({click}) => [news([button('', click)]), node('AXSheet', 'Unknown modal')], timeout);
check(({click}) => [news([]), node('AXWindow', 'Other window', [button('Continue', click)])], timeout);
check(({click}) => [news([button('', click)]), node('AXWindow', 'Other window')], timeout);
check(({click}) => [news([button('', click)])], timeout, 0, false);
check(({click}) => [news([button('Download', click)])], install);
check(({click}) => [node('AXWindow', 'Xcode', [
    node('AXStaticText', 'External Agent Access'),
    node('AXStaticText', 'Control how external coding agents can connect to Xcode'),
    node('AXRadioButton', 'Access option', [], {click}), button('Continue', click)
])], 'external-agent-access');
console.log('14 Xcode GUI acceptance cases passed.');
