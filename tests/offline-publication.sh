#!/bin/bash
set -euo pipefail
root=$(cd "$(dirname "$0")/.." && pwd)
fixture=$(cd "$(mktemp -d)" && pwd -P)
trap 'rm -rf "$fixture"' EXIT
mkdir -p "$fixture/ci" "$fixture/config/miso/test" "$fixture/bin"
cp "$root/ci/"{offline-profile.sh,promote-offline-image.sh,cleanup-offline-candidates.sh} "$fixture/ci/"
source "$fixture/ci/offline-profile.sh"
export FIXTURE="$fixture" PATH="$fixture/bin:$PATH" IMAGE_PROFILE=test VARIANT=vanilla
export GITHUB_ACTOR=cocoa-xu GH_TOKEN=fixture GITHUB_STEP_SUMMARY="$fixture/summary"
profile="$fixture/config/miso/test/profile.json"
record="$fixture/config/miso/test/acceptance-vanilla.json"
export DIGEST="sha256:$(printf '%064d' 1)"
cat > "$fixture/bin/oras" <<'MOCK'
#!/bin/bash
set -euo pipefail
printf '%s\n' "$*" >> "$FIXTURE/registry-calls"
case "$1" in
  resolve)
    if [[ "$2" == *@* || -f "$FIXTURE/published" ]]; then printf '%s\n' "$DIGEST"; else exit 1; fi ;;
  login) cat >/dev/null ;;
  tag) printf '%s\n' "$3" > "$FIXTURE/published" ;;
  *) exit 99 ;;
esac
MOCK
cat > "$fixture/bin/gh" <<'MOCK'
#!/bin/bash
set -euo pipefail
jq -n --arg digest "$DIGEST" --arg tag "$(cat "$FIXTURE/published")" \
  '[{name:$digest,metadata:{container:{tags:[$tag]}}}]'
MOCK
chmod +x "$fixture/bin/"*
reset_fixture() {
  rm -f "$fixture/published" "$fixture/registry-calls"
  : > "$fixture/summary"
}
make_receipt() {
  jq -n --slurpfile profile "$profile" --arg digest "$DIGEST" '
    {target:$profile[0].target,variant:"vanilla",reference:("ghcr.io/minimillionaire/test-vanilla@"+$digest),
     constructionVMStarted:false,anonymousDownloadVerified:true,buildRun:"https://example.test/runs/123",
     runtime:{exitCode:0,vmStopped:true,sourceUnchanged:true,rosettaInstalled:false,manualGuestRepair:false,
       checks:["credential-rotation-before-cold-boot","credential-rotation-after-cold-boot"]}}' > "$record"
}
promote() { bash "$fixture/ci/promote-offline-image.sh"; }
reject() {
  reset_fixture
  if promote > "$fixture/rejection.log" 2>&1; then
    printf 'Unexpected promotion success: %s\n' "$1" >&2; exit 1
  fi
  [[ ! -e "$fixture/registry-calls" ]]
}
printf '%s\n' '{"target":{"version":"27.0.1","build":"26A434"},"repository":"ghcr.io/minimillionaire/test"}' > "$profile"
make_receipt
reset_fixture
promote
[[ $(cat "$fixture/published") == 27.0.1 ]]
printf '%s\n' '{"target":{"version":"27.2","build":"26B118"},"publication":{"tag":"27.2-rc","prerelease":true},"repository":"ghcr.io/minimillionaire/test"}' > "$profile"
make_receipt
reject 'RC identity missing'
jq '. + {profile:"test",publication:{tag:"27.2-rc",prerelease:true}}' "$record" > "$fixture/valid-receipt"
cp "$fixture/valid-receipt" "$record"
reset_fixture
promote
[[ $(cat "$fixture/published") == 27.2-rc ]]
for mutation in '.target.build="26B119"' '.profile="other"' '.publication.prerelease=false' '.publication.tag="27.2"'; do
  jq "$mutation" "$fixture/valid-receipt" > "$record"
  reject "$mutation"
done
cp "$fixture/valid-receipt" "$record"
cp "$profile" "$fixture/valid-profile"
for mutation in '.publication.tag="27.2"' '.publication.tag="latest"' '.publication.prerelease=false' '.target.version="latest"' '.publication=null'; do
  jq "$mutation" "$fixture/valid-profile" > "$profile"
  reject "$mutation"
done
cp "$fixture/valid-profile" "$profile"
offline_receipt_matches_profile "$record" "$profile" test
if offline_receipt_matches_profile "$record" "$profile" wrong; then exit 1; fi
printf '%s\n' 'PASS: legacy stable and RC tags publish; invalid target, identity, or channel fails before registry access.'
export VARIANT=xcode XCODE_VERSION=27.2rc XCODE_FLAVOR=slim
cat > "$fixture/bin/miso" <<'MOCK'
#!/bin/bash
set -euo pipefail
[[ "$1" == xcode && "$2" == defaults ]]
printf '{"version":"27.2","build":"27B48"}\n'
MOCK
chmod +x "$fixture/bin/miso"
jq '.variant="xcode" | .reference |= sub("test-vanilla";"test-slim-xcode") |
  .xcodeConfiguration={version:"27.2",build:"27B48"} | .xcodeFlavor="slim"' \
  "$fixture/valid-receipt" > "$fixture/config/miso/test/acceptance-slim-xcode-27.2rc.json"
reset_fixture
promote
[[ $(cat "$fixture/published") == 27.2-rc-xcode27.2-rc ]]
printf '%s\n' 'PASS: Slim Xcode RC suffix preserves the macOS prerelease identity.'
source "$root/ci/image-storage.sh"
IMAGE_BUILD_WORKSPACE="$fixture/work"
RUNNER_TEMP="$fixture/temp"
mkdir "$RUNNER_TEMP"
BUILD_RUNNER_SELECTION=local
BUILD_RUNNER_ENVIRONMENT=self-hosted
TARGET_VARIANT=base
PARENT_RUN=
LOCAL_IPSW_PATH="$fixture/source.ipsw"
printf 'fixture\n' > "$LOCAL_IPSW_PATH"
image_storage_validate_ipsw
for selection in default invalid; do
  if (BUILD_RUNNER_SELECTION=$selection; image_storage_validate_ipsw); then exit 1; fi
done
if (BUILD_RUNNER_ENVIRONMENT=github-hosted; image_storage_validate_ipsw); then exit 1; fi
if (PARENT_RUN=123; image_storage_validate_ipsw); then exit 1; fi
if (TARGET_VARIANT=xcode; image_storage_validate_ipsw); then exit 1; fi
mkdir "$fixture/work"
cp "$LOCAL_IPSW_PATH" "$fixture/temp/input.ipsw"
cp "$LOCAL_IPSW_PATH" "$fixture/work/input.ipsw"
ln -s "$LOCAL_IPSW_PATH" "$fixture/link.ipsw"
for input in "$fixture/temp/input.ipsw" "$fixture/work/input.ipsw" "$fixture/link.ipsw" "https://example.test/source.ipsw" "$fixture/missing.ipsw"; do
  if (LOCAL_IPSW_PATH=$input; image_storage_validate_ipsw); then exit 1; fi
done
printf '%s\n' 'PASS: local IPSW inputs require the isolated lane and remain outside cleanup paths.'
