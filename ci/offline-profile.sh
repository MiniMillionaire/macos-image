#!/bin/bash

offline_publication() {
  jq -ce '
    if (.target.version | type == "string" and test("^[1-9][0-9]*[.](0|[1-9][0-9]*)([.](0|[1-9][0-9]*))?$")) and
       (.target.build | type == "string" and test("^[0-9]{2}[A-Z][0-9]+[a-z]?$"))
    then . else error("Invalid macOS target") end |
    .target.version as $version |
    (if has("publication") then .publication else {tag:$version,prerelease:false} end) as $publication |
    if ($publication | type == "object") and
       ($publication | keys == ["prerelease","tag"]) and
       ($publication.prerelease | type == "boolean") and
       ($publication.tag | type == "string" and length <= 64) and
       (if $publication.prerelease then
          ($publication.tag | startswith($version + "-")) and
          ($publication.tag | ltrimstr($version + "-") | test("^(rc|beta)([1-9][0-9]*)?$"))
        else $publication.tag == $version end)
    then $publication else error("Invalid image publication identity") end
  ' "$1"
}

offline_receipt_matches_profile() {
  local record=$1 profile=$2 name=$3 publication
  publication=$(offline_publication "$profile") || return 1
  jq -e --argjson target "$(jq -c .target "$profile")" --arg name "$name" \
    --argjson publication "$publication" '
    .target == $target and
    (if $publication.prerelease then .profile == $name and .publication == $publication
     else (if .profile == null then $name else .profile end) == $name and
          (if .publication == null then $publication else .publication end) == $publication end)
  ' "$record" >/dev/null
}
