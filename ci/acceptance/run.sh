#!/bin/bash
set -euo pipefail
root=$(cd "$(dirname "$0")/../.." && pwd -P)
variant=${IMAGE_TYPE:?}
[[ "$variant" == vanilla || "$variant" == base || "$variant" == xcode ]] || exit 1
image_profile=$variant
if [[ "$variant" == xcode ]]; then image_profile=base; fi
run="${ACCEPTANCE_WORKSPACE:?}"
helpers="$root/ci/acceptance/helpers"
vm=acceptance
log="$run/runtime"
export TART_HOME="$run/tart" TART_NO_AUTO_PRUNE=1
export SSH_ASKPASS="$helpers/askpass.sh" SSH_ASKPASS_REQUIRE=force DISPLAY=:0
export PATH="$run/tools/tart.app/Contents/MacOS:$PATH"
[[ -f "$TART_HOME/vms/source/disk.img" ]] || exit 1
mkdir "$log"
expected_version=$(jq -er .target.version "$run/cloud/publication.json")
expected_build=$(jq -er .target.build "$run/cloud/publication.json")
source_state() {
  stat -f '%N %i %z %b %m %c' "$TART_HOME/vms/source/"{disk.img,nvram.bin,config.json}
}
source_state > "$log/source-before.txt"
tart clone source "$vm"
if [[ "$variant" == xcode ]]; then
  tart set "$vm" --cpu 6 --memory 12288
else
  tart set "$vm" --cpu 4 --memory 8192
fi
[[ $(stat -f %i "$TART_HOME/vms/source/disk.img") != "$(stat -f %i "$TART_HOME/vms/$vm/disk.img")" ]] || exit 1
vm_pid=
watchdog_pid=
finish() {
  local status=$?
  trap - EXIT
  if [[ -n "$vm_pid" ]]; then
    if [[ "$variant" == xcode ]] && declare -F remote >/dev/null; then
      remote "/usr/bin/perl -e 'alarm 90; exec @ARGV' /bin/bash -s" < "$helpers/diagnostics.sh" > "$log/diagnostics.tar" 2> "$log/diagnostics.log" || status=1
    fi
    tart stop "$vm" --timeout 30 > "$log/stop.log" 2>&1 || status=1
    wait "$vm_pid" || true
  fi
  if [[ -n "$watchdog_pid" ]]; then
    kill "$watchdog_pid" 2>/dev/null || true
    wait "$watchdog_pid" 2>/dev/null || true
  fi
  tart get "$vm" --format json > "$log/final-state.json"
  jq -e '.State == "stopped" and .Running == false' "$log/final-state.json" >/dev/null || status=1
  source_state > "$log/source-after.txt"
  unchanged=true
  cmp "$log/source-before.txt" "$log/source-after.txt" || { unchanged=false; status=1; }
  jq --argjson code "$status" --argjson unchanged "$unchanged" \
    '{exitCode:$code,vmStarted:true,vmStopped:(.State == "stopped" and .Running == false),sourceUnchanged:$unchanged,sourceCheck:"APFS clone isolation and source inode, size, allocation, modification and change times"}' \
    "$log/final-state.json" > "$log/runtime-status.json"
  exit "$status"
}
trap finish EXIT
trap 'exit 124' TERM
controller_pid=$$
limit=1500
if [[ "$variant" == xcode ]]; then limit=3600; fi
(sleep "$limit"; kill -TERM "$controller_pid") &
watchdog_pid=$!
tart run "$vm" --no-graphics --no-audio --no-clipboard > "$log/vm.log" 2>&1 &
vm_pid=$!
printf '%s\n' "$vm_pid" > "$log/vm.pid"
tart ip "$vm" --wait 300 > "$log/ip.txt"
ip=$(cat "$log/ip.txt")
[[ "$ip" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]] || exit 1
options=(-F /dev/null -o StrictHostKeyChecking=accept-new -o "UserKnownHostsFile=$log/known_hosts" -o ConnectTimeout=5 -o ServerAliveInterval=10 -o ServerAliveCountMax=3 -o NumberOfPasswordPrompts=1 -o PubkeyAuthentication=no -o PreferredAuthentications=password)
remote() { ssh "${options[@]}" "admin@$ip" "$@"; }
vnc() {
  local privilege=(sudo -n)
  if [[ -n ${MISO_ROOT_COMMAND:-} ]]; then privilege=("$MISO_ROOT_COMMAND"); fi
  "${privilege[@]}" /usr/bin/env \
    "SSH_ASKPASS=$SSH_ASKPASS" SSH_ASKPASS_REQUIRE=force DISPLAY=:0 \
    "VNC_AUTH=${VNC_AUTH:-}" "VNC_POINTER_COMMAND=${VNC_POINTER_COMMAND:-}" \
    "VNC_CAPTURE_PATH=${VNC_CAPTURE_PATH:-}" \
    /bin/sh -c 'umask 022; exec "$@"' vnc-client "$run/tools/vnc-smoke" "$@"
}
remote_script() {
  local name=$1 file=$2
  shift 2
  printf '\n::group::%s\n' "$name"
  scp "${options[@]}" "$file" "admin@$ip:/private/tmp/miso-acceptance-step.sh" >> "$log/scp.log" 2>&1
  local status=0
  remote "env EXPECTED_VERSION=$expected_version EXPECTED_BUILD=$expected_build $* /usr/bin/perl -e 'alarm 900; exec @ARGV' /bin/bash /private/tmp/miso-acceptance-step.sh" </dev/null 2>&1 | tee "$log/$name.log" || status=$?
  printf '::endgroup::\n'
  printf '%s %s\n' "$name" "$status" >> "$log/checks.tsv"
  return "$status"
}
session_state() {
  remote 'osascript -l JavaScript -e '\''ObjC.import("CoreGraphics"); JSON.stringify(ObjC.deepUnwrap(ObjC.castRefToObject($.CGSessionCopyCurrentDictionary())))'\''' > "$log/session-$1.json"
}
ready=false
for attempt in {1..40}; do
  if remote 'test "$(stat -f %Su /dev/console)" = admin' </dev/null > "$log/ready.log" 2>&1; then ready=true; break; fi
  sleep 5
done
[[ "$ready" == true ]] || exit 1
printf "::notice::VM started; waiting for the guest desktop.\n"
scp "${options[@]}" "$root/scripts/guest/user-tcc-database.sh" "admin@$ip:/tmp/macos-image-user-tcc-database.sh" > "$log/scp.log" 2>&1
remote_script original-requirements "$root/scripts/guest/verify-image.sh" "IMAGE_PROFILE=$image_profile" IMAGE_FLAVOR=slim GUEST_USERNAME=admin ALLOW_NOTIFICATION_CENTER=true
if [[ "$variant" == xcode ]]; then
  /bin/bash "$root/ci/acceptance/xcode-config.sh" "$run/cloud" > "$log/xcode-config.json"
  scp "${options[@]}" "$log/xcode-config.json" "admin@$ip:/private/tmp/offline-xcode-config.json" >> "$log/scp.log" 2>&1
  remote_script xcode-tools "$helpers/xcode-tools.sh"
  remote_script compile "$helpers/xcode-compile.sh"
  remote_script mobile-tools "$helpers/xcode-mobile-tools.sh"
  while IFS= read -r platform; do
    remote_script "simulator-$platform" "$helpers/xcode-simulator.sh" "MISO_SIMULATOR_PLATFORM=$platform"
  done < <(jq -r '.configuration.platforms[] | ascii_downcase' "$log/xcode-config.json")
  remote 'osascript -e '\''tell application id "com.apple.dt.Devices" to quit'\'''
else
  remote_script compile "$helpers/guest.sh"
fi
if SSH_ASKPASS="$helpers/wrong-askpass.sh" remote true </dev/null > "$log/ssh-negative.log" 2>&1; then exit 1; fi
grep -q 'Permission denied' "$log/ssh-negative.log"
session_state before-vnc
vnc "$ip" admin > "$log/vnc-positive.json"
session_state after-vnc
negative=0
vnc "$ip" wrong-password > "$log/vnc-negative.json" || negative=$?
[[ "$negative" == 2 ]] || exit 1
session_state after-negative
remote 'if pkgutil --pkg-info com.apple.pkg.RosettaUpdateAuto; then exit 1; fi; test ! -e /Library/Apple/usr/libexec/oah/libRosettaRuntime' > "$log/no-rosetta.log" 2>&1
if [[ "$variant" != vanilla ]]; then
  remote_script base-tools "$helpers/base-extra.sh"
  remote_script tcc "$helpers/tcc-ready.sh"
  remote 'osascript -e '\''tell application "TextEdit" to quit'\''; rm "$HOME/Documents/base-tcc-control.txt" /private/tmp/base-tcc-screen.png'
  remote_script safari "$helpers/safari.sh"
  remote 'osascript -e '\''tell application "Safari" to quit'\'''
fi
nonce=$(openssl rand -hex 16)
witness="/private/tmp/offline-vnc-witness-$nonce.json"
scp -r "${options[@]}" "$run/tools/InputWitness.app" "admin@$ip:/private/tmp/" >> "$log/scp.log" 2>&1
remote "open -n /private/tmp/InputWitness.app --args $witness $nonce"
for attempt in {1..20}; do
  remote "cat $witness" > "$log/witness-before.json" 2> "$log/witness-read.log" || true
  if jq -e '.ready == true and .clicks == 0 and .text == "" and .window_is_key == false' "$log/witness-before.json" >/dev/null 2>&1; then break; fi
  sleep 1
done
jq -e '.ready == true and .clicks == 0 and .text == "" and .window_is_key == false' "$log/witness-before.json" >/dev/null
read -r x y focus_x width height < <(jq -r '[.target[0] + .target[2]/2, .target[1] + .target[3]/2, .target[0] - 32, .screen[2], .screen[3]] | map(floor) | @tsv' "$log/witness-before.json")
{
  printf '#!/bin/bash\nset -euo pipefail\n'
  printf '%q ' /usr/bin/ssh "${options[@]}" "admin@$ip" '/private/tmp/InputWitness.app/Contents/MacOS/InputWitness --pointer'
  printf '| /usr/bin/jq -r '\''@tsv'\''\n'
} > "$log/observe-pointer.sh"
chmod 700 "$log/observe-pointer.sh"
VNC_AUTH=ard VNC_POINTER_COMMAND="$log/observe-pointer.sh" VNC_CAPTURE_PATH="$log/frame.ppm" vnc "$ip" admin "$x" "$y" "$focus_x" "$width" "$height" "$nonce" > "$log/vnc-input.json"
remote "cat $witness" > "$log/witness-after.json"
jq -e --arg nonce "$nonce" '.nonce == $nonce and .clicks == 1 and .text == $nonce and .window_is_key and .application_active' "$log/witness-after.json" >/dev/null
session_state after-input
negative=0
VNC_AUTH=ard vnc "$ip" wrong-password > "$log/ard-negative.json" || negative=$?
[[ "$negative" == 2 ]] || exit 1
session_state after-ard-negative
witness_pid=$(jq -er '.pid | select(. > 1)' "$log/witness-after.json")
remote "kill $witness_pid; rm -rf /private/tmp/InputWitness.app; rm $witness"
session_state after-witness
remote 'stat -f %Su /dev/console; ps -axo pid,ppid,etime,comm | egrep "(Finder|Dock|screensharing|loginwindow)"' > "$log/desktop-processes.txt"
remote_script health "$helpers/health.sh"
grep -qx 'BOOT_EVENTS=1' "$log/health.log"
if [[ "$variant" == xcode ]]; then remote_script dismiss-notifications "$helpers/dismiss-notifications.sh"; fi
remote_script final-desktop "$root/scripts/guest/verify-image.sh" "IMAGE_PROFILE=$image_profile" IMAGE_FLAVOR=slim GUEST_USERNAME=admin ALLOW_NOTIFICATION_CENTER=true
printf 'RUNTIME_ACCEPTANCE_PASSED\n'
