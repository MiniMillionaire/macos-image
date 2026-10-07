#!/bin/bash
set -euo pipefail
cloud=${1:?Build evidence required}
version=${XCODE_VERSION:?}
[[ "$version" =~ ^[A-Za-z0-9][A-Za-z0-9._-]*$ && "$version" != *..* ]]
jq --slurpfile inputs "$cloud/xcode-$version-inputs.json" \
  --slurpfile casks "$cloud/prepare-casks.json" \
  --slurpfile gems "$cloud/gems.json" \
  --slurpfile tuist "$cloud/prepare-tuist.json" \
  --slurpfile simulator "$cloud/prepare-simulator-tools.json" \
  --slurpfile flutter "$cloud/prepare-flutter.json" \
  --slurpfile android "$cloud/prepare-android.json" '
  {configuration, sdks:.application.sdks, runtimes:$inputs[0].runtimes,
   versions: ({tuist:$tuist[0].formula.version, applesimutils:$simulator[0].formula.version}
     + ($casks[0].items | map({key:.cask.token,value:.cask.version}) | from_entries)
     + ($gems[0].packages | map({key:.name,value:.version}) | from_entries)),
   flutter:$flutter[0].version,
   android:($android[0].selection.packages | map({key:.identifier,value:.revision}) | from_entries)}
  ' "$cloud/archive.json"
