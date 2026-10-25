#!/bin/bash
set -euo pipefail
root=$(cd "$(dirname "$0")/.." && pwd -P)
source=${1:?Source Tart image required}
configuration=${2:?Xcode configuration required}
requirements=${3:?Runtime requirements required}
work=${4:?Output directory required}
[[ "$source" == /* && "$work" == /* && ! -e "$work" && ! -L "$source" ]]
for file in disk.img nvram.bin config.json; do
  [[ -f "$source/$file" && ! -L "$source/$file" ]]
done
mkdir -p "$work/tart/vms" "$work/evidence"
export TART_HOME="$work/tart" TART_NO_AUTO_PRUNE=1
export SSH_ASKPASS="$root/ci/acceptance/helpers/askpass.sh" SSH_ASKPASS_REQUIRE=force DISPLAY=:0
source_state() { stat -f '%N %i %z %b %m %c' "$source/"{disk.img,nvram.bin,config.json}; }
source_state > "$work/evidence/source-before.txt"
ln -s "$source" "$TART_HOME/vms/source"
tart clone source builder
tart set builder --cpu 6 --memory 12288
vm_pid=
completed=false
finish() {
  status=$?
  trap - EXIT
  if [[ -n "$vm_pid" ]]; then
    if [[ ${ready:-false} == true ]]; then
      remote 'sudo -n /sbin/shutdown -h now' </dev/null > "$work/evidence/shutdown.log" 2>&1 || true
      for attempt in {1..30}; do
        kill -0 "$vm_pid" 2>/dev/null || break
        sleep 1
      done
    fi
    tart stop builder --timeout 30 > "$work/evidence/stop.log" 2>&1 || status=1
    wait "$vm_pid" || true
  fi
  tart get builder --format json > "$work/evidence/final-state.json"
  jq -e '.State == "stopped" and .Running == false' "$work/evidence/final-state.json" >/dev/null || status=1
  source_state > "$work/evidence/source-after.txt"
  cmp "$work/evidence/source-before.txt" "$work/evidence/source-after.txt" || status=1
  if [[ "$completed" != true ]]; then status=1; fi
  if [[ "$status" == 0 && "$completed" == true ]]; then
    tart set builder --cpu "$(jq -er .cpuCount "$source/config.json")" \
      --memory "$(jq -er '.memorySize / 1048576 | floor' "$source/config.json")"
    jq '. + {vmStopped:true,sourceUnchanged:true}' "$work/evidence/native-components.json" \
      > "$work/evidence/native-components-final.json"
    mv "$work/evidence/native-components-final.json" "$work/evidence/native-components.json"
    mv "$TART_HOME/vms/builder" "$work/vm"
  fi
  exit "$status"
}
trap finish EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
tart run builder --no-graphics --no-audio --no-clipboard > "$work/evidence/vm.log" 2>&1 &
vm_pid=$!
printf '%s\n' "$vm_pid" > "$work/evidence/vm.pid"
tart ip builder --wait 180 > "$work/evidence/ip.txt"
ip=$(cat "$work/evidence/ip.txt")
[[ "$ip" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]
options=(-F /dev/null -o StrictHostKeyChecking=accept-new -o "UserKnownHostsFile=$work/evidence/known_hosts"
  -o ConnectTimeout=5 -o ServerAliveInterval=15 -o ServerAliveCountMax=3
  -o PubkeyAuthentication=no -o PreferredAuthentications=password -o NumberOfPasswordPrompts=1)
remote() { ssh "${options[@]}" "admin@$ip" "$@"; }
ready=false
for attempt in {1..120}; do
  if remote true </dev/null > "$work/evidence/ssh-ready.log" 2>&1; then ready=true; break; fi
  kill -0 "$vm_pid" || exit 1
  sleep 0.5
done
[[ "$ready" == true ]]
remote 'mkdir /private/tmp/macos-image-components'
scp "${options[@]}" "$configuration" "admin@$ip:/private/tmp/macos-image-components/xcode.json"
scp "${options[@]}" "$requirements" "admin@$ip:/private/tmp/macos-image-components/requirements.json"
scp "${options[@]}" "$root/ci/acceptance/helpers/runtime-inventory.jq" \
  "admin@$ip:/private/tmp/macos-image-components/runtime-inventory.jq"
scp "${options[@]}" "$root/ci/xcode-runtime-removals.jq" \
  "admin@$ip:/private/tmp/macos-image-components/runtime-removals.jq"
result=0
remote '/usr/bin/perl -e '\''alarm 10800; exec @ARGV'\'' /bin/bash -s' \
  < "$root/ci/guest-xcode-components.sh" > "$work/evidence/install.log" 2>&1 || result=$?
remote 'tar -cf - -C /private/tmp macos-image-components' \
  > "$work/evidence/components.tar" 2> "$work/evidence/collect.log"
tar -xf "$work/evidence/components.tar" -C "$work/evidence"
[[ "$result" == 0 ]] || { tail -n 25 "$work/evidence/install.log" >&2; exit "$result"; }
jq -e '.completed == true and .method == "xcodebuild"' \
  "$work/evidence/macos-image-components/receipt.json" > /dev/null
cp "$work/evidence/macos-image-components/receipt.json" "$work/evidence/native-components.json"
remote 'rm -r /private/tmp/macos-image-components'
remote 'sudo -n /sbin/shutdown -h now' </dev/null > "$work/evidence/shutdown.log" 2>&1 || true
for attempt in {1..120}; do
  kill -0 "$vm_pid" 2>/dev/null || break
  sleep 1
done
if kill -0 "$vm_pid" 2>/dev/null; then printf 'Component installation guest did not shut down.\n' >&2; exit 1; fi
wait "$vm_pid"
vm_pid=
completed=true
