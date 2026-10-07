#!/bin/bash
set -euo pipefail
work=${ACCEPTANCE_WORKSPACE:?}
runtime="$work/runtime/runtime-status.json"
jq -e '.exitCode == 0 and .vmStopped and .sourceUnchanged' "$runtime" >/dev/null
diagnostics='Health and boot checks retained; crash archive not collected.'
if [[ -s "$work/runtime/diagnostics.tar" ]]; then
  diagnostics='Crash archive and health checks retained in the acceptance artifact.'
  tar -tf "$work/runtime/diagnostics.tar" > "$work/evidence/diagnostic-files.txt"
  if grep -Eq '[.]panic$' "$work/evidence/diagnostic-files.txt"; then exit 1; fi
fi
jq -n --slurpfile publication "$work/cloud/publication.json" \
  --slurpfile runtime "$runtime" \
  --slurpfile build "$work/evidence/build-run.json" \
  --arg date "$(date -u +%FT%TZ)" --arg model "$(sysctl -n hw.model)" \
  --arg macos "$(sw_vers -productVersion)" --arg os_build "$(sw_vers -buildVersion)" \
  --arg tart "$TART_VERSION" \
  --arg diagnostics "$diagnostics" \
  --arg run "https://github.com/$GITHUB_REPOSITORY/actions/runs/$GITHUB_RUN_ID" \
  --rawfile checks "$work/runtime/checks.tsv" '
  $publication[0] as $p |
  {schemaVersion:1,target:$p.target,variant:$p.variant,reference:$p.reference,
   sourceRevision:$p.revision,buildRun:$build[0].url,acceptanceRun:$run,
   anonymousDownloadVerified:true,constructionVMStarted:false,acceptedAt:$date,
   xcodeFlavor:$p.xcodeFlavor,
   runtime:($runtime[0] + {rosettaInstalled:false,manualGuestRepair:false,
     desktopPolicy:{allowedNotificationCenterWindows:1,otherApplicationWindows:0},
     host:{model:$model,macOS:$macos,build:$os_build,tart:$tart},
     checks:($checks | split("\n") | map(select(length > 0) | split(" ")[0])),
     authenticationAndInputVerified:true,diagnostics:$diagnostics})}' \
  > "$work/evidence/acceptance.json"
if [[ "$IMAGE_TYPE" == xcode ]]; then
  jq --slurpfile xcode "$work/runtime/xcode-config.json" \
    '. + {xcodeConfiguration:$xcode[0].configuration}' "$work/evidence/acceptance.json" \
    > "$work/evidence/acceptance-xcode.json"
  mv "$work/evidence/acceptance-xcode.json" "$work/evidence/acceptance.json"
fi
if [[ -f "$work/cloud/inherited-xcode.json" ]]; then
  jq --slurpfile parent "$work/cloud/inherited-xcode.json" \
    '.supersededCandidate = ($parent[0] | {reference,run})' "$work/evidence/acceptance.json" \
    > "$work/evidence/acceptance-derived.json"
  mv "$work/evidence/acceptance-derived.json" "$work/evidence/acceptance.json"
fi
printf 'Runtime acceptance passed for `%s`. The disposable VM is stopped and the source is unchanged.\n' \
  "$(jq -r .reference "$work/evidence/acceptance.json")" >> "$GITHUB_STEP_SUMMARY"
