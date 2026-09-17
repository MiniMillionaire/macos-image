#!/usr/bin/env bash
set -euo pipefail

database="$HOME/Library/Application Support/com.apple.TCC/TCC.db"
if [[ -f "$database" ]]; then
  printf '%s\n' "$database"
  exit 0
fi

deadline=$((SECONDS + 30))
while (( SECONDS < deadline )); do
  database=$(sudo lsof -n -a -u "$(id -u)" -c tccd -Fn |
    sed -n 's|^n\(.*[/]com\.apple\.TCC/TCC\.db\)$|\1|p' | sort -u) || database=
  if [[ -f "$database" ]]; then
    printf '%s\n' "$database"
    exit 0
  fi
  sleep 1
done

echo 'Could not locate the user TCC database' >&2
exit 1
