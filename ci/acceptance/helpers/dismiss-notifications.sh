#!/bin/bash
set -euo pipefail
osascript -l JavaScript <<'JAVASCRIPT'
const events = Application('System Events');
const center = events.processes.byName('NotificationCenter');
if (center.exists()) {
    for (let attempt = 0; attempt < 5 && center.windows().length; attempt++) {
        const pending = center.windows();
        let examined = 0;
        let dismissed = false;
        while (pending.length && examined++ < 512 && !dismissed) {
            const element = pending.shift();
            const actions = element.actions();
            for (const action of actions) {
                const description = action.description();
                if (/^(Close|Clear All|Dismiss)$/i.test(description)) {
                    action.perform();
                    dismissed = true;
                    break;
                }
            }
            if (!dismissed && element.role() === 'AXButton' &&
                /^(Close|Clear All|Dismiss)$/i.test(element.description() || element.name())) {
                element.click();
                dismissed = true;
            }
            if (!dismissed) pending.push(...element.uiElements());
        }
        if (!dismissed) break;
        delay(0.5);
    }
}
JAVASCRIPT
