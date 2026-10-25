#!/bin/bash

verify_credential_rotation() {
  local label=$1 replacement ready=false
  replacement=$(openssl rand -hex 24)
  printf '/usr/sbin/sysadminctl -adminUser admin -adminPassword admin -resetPasswordFor admin -newPassword %s\n' "$replacement" |
    remote /bin/sh -s > "$log/credential-reset-$label.log" 2>&1
  for attempt in {1..15}; do
    if GUEST_PASSWORD="$replacement" remote true </dev/null > "$log/credential-new-$label.log" 2>&1; then
      ready=true
      break
    fi
    sleep 3
  done
  [[ "$ready" == true ]] || return 1
  if remote true </dev/null > "$log/credential-old-$label.log" 2>&1; then return 1; fi
  grep -q 'Permission denied' "$log/credential-old-$label.log"
  printf '/usr/sbin/sysadminctl -adminUser admin -adminPassword %s -resetPasswordFor admin -newPassword admin\n' "$replacement" |
    GUEST_PASSWORD="$replacement" remote /bin/sh -s > "$log/credential-restore-$label.log" 2>&1
  remote true </dev/null > "$log/credential-restored-$label.log" 2>&1
  printf 'credential-rotation-%s 0\n' "$label" >> "$log/checks.tsv"
}

verify_credential_persistence() {
  verify_credential_rotation before-cold-boot
  remote '/usr/sbin/sysctl -n kern.boottime' > "$log/credential-boot-before.txt"
  local status=0 ready=false
  remote 'sudo -n /sbin/shutdown -h now' </dev/null > "$log/credential-shutdown.log" 2>&1 || status=$?
  [[ "$status" == 0 || "$status" == 255 ]] || return "$status"
  for attempt in {1..60}; do
    if ! kill -0 "$vm_pid" 2>/dev/null; then break; fi
    sleep 1
  done
  if kill -0 "$vm_pid" 2>/dev/null; then return 1; fi
  wait "$vm_pid"
  vm_pid=
  tart get "$vm" --format json > "$log/credential-stopped.json"
  jq -e '.State == "stopped" and .Running == false' "$log/credential-stopped.json" >/dev/null
  tart run "$vm" --no-graphics --no-audio --no-clipboard > "$log/vm-credentials.log" 2>&1 &
  vm_pid=$!
  printf '%s\n' "$vm_pid" > "$log/vm.pid"
  tart ip "$vm" --wait 300 > "$log/ip.txt"
  ip=$(cat "$log/ip.txt")
  [[ "$ip" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]] || return 1
  for attempt in {1..120}; do
    if remote true </dev/null > "$log/credential-cold-boot.log" 2>&1; then ready=true; break; fi
    kill -0 "$vm_pid" || return 1
    sleep 0.25
  done
  [[ "$ready" == true ]] || return 1
  remote '/usr/sbin/sysctl -n kern.boottime' > "$log/credential-boot-after.txt"
  if cmp -s "$log/credential-boot-before.txt" "$log/credential-boot-after.txt"; then return 1; fi
  verify_credential_rotation after-cold-boot
  printf 'Credential rotation survived a complete VM shutdown and cold boot.\n'
}
