#!/bin/bash
set -euo pipefail
source "$HOME/.zprofile"
export HOMEBREW_NO_AUTO_UPDATE=1 HOMEBREW_NO_ANALYTICS=1 HOMEBREW_NO_INSTALL_CLEANUP=1 HOMEBREW_NO_INSTALL_FROM_API=1
brew missing
brew linkage --test
brew list --versions
for binary in "$HOME"/.rbenv/versions/*/bin/ruby; do
  "$binary" -ropenssl -rpsych -rzlib -e 'puts [RUBY_DESCRIPTION, OpenSSL::OPENSSL_VERSION, Psych::VERSION, Zlib::VERSION]'
done
[[ -x "$HOME/.rbenv/versions/2.7.8/bin/ruby" ]]
ruby --version
bundle --version
node --version
npm --version
yarn --version
pnpm --version
node -e 'require("node:assert/strict").equal(2 + 2, 4)'
tart-guest-agent --version
/usr/local/bin/git-credential-manager --version
git lfs version
[[ $(git config --global --get credential.https://dev.azure.com.useHttpPath) == true ]]
[[ -n $(git config --global --get-all credential.helper) ]]
csrutil status | grep -F 'disabled'
csrutil authenticated-root status | grep -F 'enabled'
automationmodetool status
for right in authenticate-webdeveloper is-webdeveloper com.apple.safaridriver.allow; do
  sudo -n security authorizationdb read "$right"
done
[[ $(defaults read /Library/Preferences/com.apple.TimeMachine AutoBackup) == 0 ]]
for volume in / /System/Volumes/Data /System/Volumes/Preboot; do
  deadline=$((SECONDS + 120))
  while true; do
    result=$(mdutil -s "$volume" 2>&1) || true
    if [[ "$result" == *'Indexing disabled.'* ]]; then break; fi
    [[ "$result" == *'unknown indexing state'* || "$result" == *'Index is already changing state'* ]]
    (( SECONDS < deadline ))
    sleep 5
  done
  printf '%s\n' "$result"
done
python_binary=$(find /opt/homebrew/opt/python@*/bin -maxdepth 1 -type l -name 'python3.*' ! -name '*-config' | sort | tail -n 1)
[[ -n "$python_binary" ]]
"$python_binary" -I -c 'import ssl; count = ssl.create_default_context().cert_store_stats()["x509_ca"]; print("CA count:", count); assert count >= 150'
printf 'BASE_TOOLS_PASSED\n'
