#!/bin/bash
set -euo pipefail
list=$(mktemp /private/tmp/miso-diagnostics.XXXXXXXX)
trap 'rm -f "$list" "$list.paths"' EXIT
directories=()
for directory in /Library/Logs/DiagnosticReports "$HOME/Library/Logs/DiagnosticReports"; do
  if [[ -d "$directory" ]]; then directories+=("$directory"); fi
done
: > "$list.paths"
if (( ${#directories[@]} > 0 )); then
  sudo -n find "${directories[@]}" -type f \( -name '*.ips' -o -name '*.panic' \) -print0 > "$list.paths"
fi
total=0
count=0
while IFS= read -r -d '' report; do
  bytes=$(stat -f %z "$report")
  total=$((total + bytes))
  count=$((count + 1))
  (( bytes <= 4194304 && total <= 67108864 && count <= 256 )) || exit 1
  printf '%s\0' "$report" >> "$list"
done < "$list.paths"
printf 'Diagnostic reports: %s files, %s bytes\n' "$count" "$total" >&2
sudo -n tar -cf - --null -T "$list"
