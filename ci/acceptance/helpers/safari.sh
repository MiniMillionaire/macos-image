#!/bin/bash
set -euo pipefail
export PATH=/opt/homebrew/opt/node@24/bin:/opt/homebrew/bin:/usr/bin:/bin:/usr/sbin:/sbin
/usr/bin/safaridriver --version
/usr/bin/safaridriver -p 4444 >/tmp/offline-base-safaridriver.log 2>&1 &
driver_pid=$!
trap 'kill "$driver_pid" 2>/dev/null || true' EXIT
for attempt in {1..20}; do
    if /usr/bin/curl -fsS --max-time 1 http://127.0.0.1:4444/status >/dev/null 2>&1; then break; fi
    sleep 0.25
done
session=$(/usr/bin/curl -fsS --max-time 50 -H 'Content-Type: application/json' -d '{"capabilities":{"alwaysMatch":{"browserName":"safari"}}}' http://127.0.0.1:4444/session)
printf '%s\n' "$session"
identifier=$(printf '%s' "$session" | /opt/homebrew/bin/jq -er '.value.sessionId')
endpoint="http://127.0.0.1:4444/session/$identifier"
/usr/bin/curl -fsS --max-time 20 -H 'Content-Type: application/json' -d '{"url":"data:text/html,<title>Offline Base WebDriver</title><h1 id=proof>macOS offline Base</h1>"}' "$endpoint/url"
result=$(/usr/bin/curl -fsS --max-time 20 -H 'Content-Type: application/json' -d '{"script":"return {title:document.title,text:document.getElementById(\"proof\").textContent,userAgent:navigator.userAgent}","args":[]}' "$endpoint/execute/sync")
printf '%s\n' "$result"
printf '%s' "$result" | /opt/homebrew/bin/jq -e '.value.title == "Offline Base WebDriver" and .value.text == "macOS offline Base"'
/usr/bin/curl -fsS --max-time 10 -X DELETE "$endpoint"
