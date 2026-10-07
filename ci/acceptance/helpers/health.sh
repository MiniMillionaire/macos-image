#!/bin/bash
miso_boot_events() (
    set -euo pipefail
    directory=${1:?log directory required}
    shopt -s nullglob
    logs=("$directory"/system.log*)
    test "${#logs[@]}" -gt 0 && test "${#logs[@]}" -le 16 || exit 64
    total=0
    for log in "${logs[@]}"; do
        test -f "$log" && test ! -L "$log" || exit 64
        name=${log##*/}
        [[ "$name" == system.log || "$name" =~ ^system[.]log[.](T[0-9]+|[0-9]+)([.]gz)?$ ]] || exit 64
        bytes=$(/usr/bin/stat -f '%z' "$log") || exit 64
        test "$bytes" -le 16777216 || exit 64
        total=$((total + bytes))
        test "$total" -le 67108864 || exit 64
    done
    for log in "${logs[@]}"; do
        case "$log" in
            *.gz) /usr/bin/gzcat "$log" || exit 65 ;;
            *) /bin/cat "$log" || exit 65 ;;
        esac
    done | /usr/bin/awk '
        /BOOT_TIME/ {
            if ($0 !~ /bootlog\[0\]: BOOT_TIME [0-9]+ [0-9]+$/) { invalid=1; exit 64 }
            count++
        }
        END { if (invalid) exit 64; print count+0 }
    '
)

miso_guest_boot_events() {
    sudo -n /bin/bash -c "$(declare -f miso_boot_events); miso_boot_events /private/var/log"
}

set -euo pipefail
date -u
sw_vers
id
sysctl kern.boottime
uptime
csrutil status
csrutil authenticated-root status
printf 'CONSOLE='; stat -f %Su /dev/console
printf 'BOOT_EVENTS='; miso_guest_boot_events
printf 'TART_PROCESSES='; pgrep -fl tart-guest-agent || true
printf 'TART_VERSION_DEVICES='; find /dev -maxdepth 1 -name 'cu.tart-version-*' -print
