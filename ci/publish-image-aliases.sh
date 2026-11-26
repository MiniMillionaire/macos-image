#!/usr/bin/env bash
set -euo pipefail
umask 077

fail() { printf '%s\n' "$1" >&2; exit 1; }
safe_name() { [[ "$1" =~ ^[A-Za-z0-9][A-Za-z0-9._-]*$ && "$1" != *..* ]]; }
safe_name "${LOCAL_PUBLICATION:-}" || fail 'Invalid local publication ID.'
safe_name "${IMAGE_PROFILE:-}" || fail 'Invalid image profile.'
[[ ${1:-} == '' || ${1:-} == --check ]] || fail 'Usage: publish-image-aliases.sh [--check]'
root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
directory="$HOME/.local/share/macos-image/publications/$LOCAL_PUBLICATION"
receipt="$directory/publication.json"
profile="$root/config/miso/$IMAGE_PROFILE/profile.json"
[[ -f "$receipt" && ! -L "$receipt" && ! -L "$directory" && -f "$profile" ]] || fail 'Publication receipt or profile is missing.'
jq -e --arg profile "$IMAGE_PROFILE" --slurpfile configuration "$profile" '
  .status == "published" and .anonymousManifestVerified == true and .anonymousConfigVerified == true and
  .acceptance.profile == $profile and .acceptance.target == $configuration[0].target and
  .acceptance.customTag == .tag and .acceptance.reviewAccepted == true and .acceptance.runtime.exitCode == 0 and
  .acceptance.runtime.vmStopped == true and .acceptance.runtime.sourceUnchanged == true and
  (.acceptance.prerelease | type == "boolean")
' "$receipt" >/dev/null || fail 'Aliases require an accepted, verified publication.'
if [[ $(jq -r .acceptance.prerelease "$receipt") == true ]]; then
  printf 'Skipping stable aliases for a prerelease image.\n'
  exit 0
fi
variant=$(jq -er .acceptance.variant "$receipt")
case "$variant" in
  vanilla|base) package_variant=$variant; expected_tag=$(jq -er .acceptance.target.version "$receipt"); aliases=(latest) ;;
  xcode|xcode-slim)
    package_variant=xcode
    [[ "$variant" != xcode-slim ]] || package_variant=slim-xcode
    xcode=$(jq -er .acceptance.xcodeConfiguration.version "$receipt")
    [[ "$xcode" =~ ^(0|[1-9][0-9]*)(\.(0|[1-9][0-9]*)){0,2}$ ]] || fail 'Invalid stable Xcode version.'
    expected_tag="$(jq -er .acceptance.target.version "$receipt")-xcode$xcode"
    aliases=("$xcode" latest)
    ;;
  *) fail 'Unsupported publication variant.' ;;
esac
tag=$(jq -er .tag "$receipt")
if [[ "$tag" != "$expected_tag" ]]; then
  printf 'Skipping stable aliases for a custom image tag.\n'
  exit 0
fi
repository="$(jq -er .repository "$profile")-$package_variant"
[[ "$repository" =~ ^ghcr\.io/minimillionaire/[a-z0-9][a-z0-9-]+$ ]] || fail 'Invalid image repository.'
reference=$(jq -er .reference "$receipt")
[[ "$reference" == "$repository@sha256:"* && "${reference##*@}" =~ ^sha256:[0-9a-f]{64}$ ]] || fail 'Invalid published reference.'
candidate=$(jq -c '{os:.acceptance.target.version, xcode:(.acceptance.xcodeConfiguration.version // null)}' "$receipt")
jq -e --argjson candidate "$candidate" --arg alias latest -f "$root/ci/image-alias-order.jq" <<< "$candidate" >/dev/null
temporary=$(mktemp -d "${TMPDIR:-/tmp}/image-aliases.XXXXXX")
trap 'rm -rf -- "$temporary"' EXIT
registry_repository=${repository#ghcr.io/}
anonymous=$(curl --fail --silent --show-error --proto '=https' --connect-timeout 30 --max-time 60 \
  --get --data-urlencode service=ghcr.io --data-urlencode "scope=repository:$registry_repository:pull" \
  https://ghcr.io/token | jq -er .token)
fetch_manifest() {
  curl --silent --show-error --proto '=https' --connect-timeout 30 --max-time 60 --max-filesize 4194304 \
    --header "Authorization: Bearer $anonymous" --header 'Accept: application/vnd.oci.image.manifest.v1+json' \
    --output "$temporary/manifest.json" --write-out '%{http_code}' "https://ghcr.io/v2/$registry_repository/manifests/$1"
}
manifest_digest() { printf 'sha256:%s\n' "$(shasum -a 256 "$temporary/manifest.json" | awk '{print $1}')"; }
[[ $(fetch_manifest "$tag") == 200 && $(manifest_digest) == "${reference##*@}" ]] || fail 'Published version tag changed.'
printf '{}\n' > "$temporary/anonymous.json"
printf '[]\n' > "$temporary/results.json"
for alias in "${aliases[@]}"; do
  status=$(fetch_manifest "$alias")
  previous=
  decision=update
  if [[ "$status" == 200 ]]; then
    previous=$(manifest_digest)
    if [[ "$previous" == "${reference##*@}" ]]; then
      decision=unchanged
    else
      config_digest=$(jq -er .config.digest "$temporary/manifest.json")
      [[ "$config_digest" =~ ^sha256:[0-9a-f]{64}$ ]] || fail 'Invalid existing alias configuration.'
      curl --fail --silent --show-error --location --proto '=https' --proto-redir '=https' \
        --connect-timeout 30 --max-time 60 --max-filesize 4194304 --header "Authorization: Bearer $anonymous" \
        --output "$temporary/config.json" "https://ghcr.io/v2/$registry_repository/blobs/$config_digest"
      [[ "sha256:$(shasum -a 256 "$temporary/config.json" | awk '{print $1}')" == "$config_digest" ]] || fail 'Alias configuration digest mismatch.'
      identity=$(jq -ec '.config.Labels | select((."dev.macos-image.prerelease" // "false") == "false") |
        {os:."dev.macos-image.version", xcode:(."dev.macos-image.xcode-version" // null)}' "$temporary/config.json")
      advance=$(jq -r --argjson candidate "$candidate" --arg alias "$alias" -f "$root/ci/image-alias-order.jq" <<< "$identity")
      [[ "$advance" == true || "$advance" == false ]] || fail 'Invalid alias ordering decision.'
      [[ "$advance" == true ]] || decision=skipped_older
    fi
  elif [[ "$status" != 404 ]]; then
    fail "Cannot inspect existing alias (HTTP $status)."
  fi
  jq --arg tag "$alias" --arg previous "$previous" --arg reference "$reference" --arg decision "$decision" \
    '. + [{tag:$tag, previousDigest:$previous, reference:$reference, decision:$decision}]' \
    "$temporary/results.json" > "$temporary/results.next"
  mv "$temporary/results.next" "$temporary/results.json"
  printf 'Plan %s:%s %s\n' "$repository" "$alias" "$decision"
done
if [[ ${1:-} != --check ]]; then
  while IFS=$'\t' read -r alias previous; do
    [[ -n ${MISO_REGISTRY_USERNAME:-} && -n ${MISO_REGISTRY_PASSWORD:-} ]] || fail 'Registry credentials are missing.'
    [[ $(fetch_manifest "$tag") == 200 && $(manifest_digest) == "${reference##*@}" ]] || fail 'Published version tag changed after preflight.'
    status=$(fetch_manifest "$alias")
    if [[ -z "$previous" ]]; then
      [[ "$status" == 404 ]] || fail 'Alias appeared after preflight.'
    else
      [[ "$status" == 200 && $(manifest_digest) == "$previous" ]] || fail 'Alias changed after preflight.'
    fi
    printf '%s' "$MISO_REGISTRY_PASSWORD" | oras tag "$reference" "$alias" \
      --username "$MISO_REGISTRY_USERNAME" --password-stdin --registry-config "$temporary/anonymous.json" \
      > "$temporary/tag.log"
    [[ $(fetch_manifest "$alias") == 200 && $(manifest_digest) == "${reference##*@}" ]] || fail 'Published alias does not match the accepted digest.'
    printf 'Verified %s:%s at %s\n' "$repository" "$alias" "${reference##*@}"
  done < <(jq -r '.[] | select(.decision == "update") | [.tag, .previousDigest] | @tsv' "$temporary/results.json")
  cp "$temporary/results.json" "$directory/aliases.json.next"
  mv "$directory/aliases.json.next" "$directory/aliases.json"
fi
