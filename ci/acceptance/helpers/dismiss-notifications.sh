#!/bin/bash
set -euo pipefail
osascript -l JavaScript <<'JAVASCRIPT'
const events = Application('System Events');
const center = events.processes.byName('NotificationCenter');
function readElement(operation, fallback) {
    try { return operation(); }
    catch (error) {
        if (error.errorNumber !== -1728) throw error;
        return fallback;
    }
}
if (center.exists()) {
    for (let attempt = 0; attempt < 5; attempt++) {
        const pending = readElement(() => center.windows(), []);
        let examined = 0;
        let dismissed = false;
        while (pending.length && examined++ < 512 && !dismissed) {
            const element = pending.shift();
            const actions = readElement(() => element.actions(), []);
            for (const action of actions) {
                const description = readElement(() => action.description(), '');
                if (/^(Close|Clear All|Dismiss)$/i.test(description)) {
                    dismissed = readElement(() => {
                        action.perform();
                        return true;
                    }, false);
                    if (dismissed) break;
                }
            }
            if (!dismissed && readElement(() => element.role(), '') === 'AXButton' &&
                /^(Close|Clear All|Dismiss)$/i.test(readElement(() => element.description() || element.name(), ''))) {
                dismissed = readElement(() => {
                    element.click();
                    return true;
                }, false);
            }
            if (!dismissed) pending.push(...readElement(() => element.uiElements(), []));
        }
        if (!dismissed) break;
        delay(0.5);
    }
}
JAVASCRIPT
