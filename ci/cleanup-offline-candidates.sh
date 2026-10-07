#!/usr/bin/env bash
set -euo pipefail

repository=${1:?Repository is required}
tag=${2:?Published tag is required}
digest=${3:?Accepted digest is required}
prefix=${4:?Candidate prefix is required}
[[ "$repository" =~ ^ghcr.io/([a-z0-9-]+)/([a-z0-9.-]+)$ ]] || exit 1
owner=${BASH_REMATCH[1]}
package=${BASH_REMATCH[2]}
[[ "$tag" =~ ^[A-Za-z0-9][A-Za-z0-9._-]*$ && "$prefix" == miso-* ]] || exit 1
[[ "$digest" =~ ^sha256:[0-9a-f]{64}$ ]] || exit 1
scratch=$(mktemp -d)
trap 'rm -rf "$scratch"' EXIT
printf '{}\n' > "$scratch/anonymous.json"
printf '{}\n' > "$scratch/registry.json"
endpoint="orgs/$owner/packages/container/$package/versions"
published="$repository:$tag"
[[ $(oras resolve "$published" --registry-config "$scratch/anonymous.json") == "$digest" ]] || exit 1
gh api --paginate "$endpoint?per_page=100" > "$scratch/versions.json"
if [[ -n ${5:-} ]]; then
  superseded=$5
  [[ "$superseded" =~ ^sha256:[0-9a-f]{64}$ && "$superseded" != "$digest" ]] || exit 1
  jq -rs --arg digest "$superseded" --arg prefix "$prefix" '
    add | map(select(.name == $digest and (.metadata.container.tags | length > 0))) |
    .[] | if all(.metadata.container.tags[]; startswith($prefix) and
      (ltrimstr($prefix) | test("^[0-9]+$"))) then .id
      else error("Superseded image still has tags outside this build") end
  ' "$scratch/versions.json" > "$scratch/superseded.txt"
  while IFS= read -r id; do
    [[ "$id" =~ ^[0-9]+$ ]] || exit 1
    [[ $(oras resolve "$published" --registry-config "$scratch/anonymous.json") == "$digest" ]] || exit 1
    gh api --method DELETE "$endpoint/$id"
    [[ $(oras resolve "$published" --registry-config "$scratch/anonymous.json") == "$digest" ]] || exit 1
    gh api --paginate "$endpoint?per_page=100" | jq -es --arg digest "$superseded" \
      'add | all(.[]; .name != $digest or (.metadata.container.tags | length == 0))' >/dev/null
    printf 'Removed superseded candidate: %s\n' "$superseded"
  done < "$scratch/superseded.txt"
  exit 0
fi
jq -rs --arg digest "$digest" --arg tag "$tag" --arg prefix "$prefix" '
  add | . as $versions |
  map(select(.name == $digest and (.metadata.container.tags | index($tag)))) |
  if length != 1 then error("Published package version is ambiguous") else $versions end |
  [.[].metadata.container.tags[] | select(startswith($prefix) and
    (ltrimstr($prefix) | test("^[0-9]+$")))] | unique | .[]
' "$scratch/versions.json" > "$scratch/candidates.txt"
[[ -s "$scratch/candidates.txt" ]] || exit 0
printf '%s' "$GH_TOKEN" | oras login ghcr.io --username "$GITHUB_ACTOR" \
  --password-stdin --registry-config "$scratch/registry.json"
oras manifest fetch "$repository@$digest" --registry-config "$scratch/registry.json" > "$scratch/original.json"
media_type=$(jq -er .mediaType "$scratch/original.json")
while IFS= read -r candidate; do
  [[ "$candidate" != "$tag" ]] || exit 1
  candidate_digest=$(oras resolve "$repository:$candidate" --registry-config "$scratch/registry.json")
  jq -S --arg tag "$candidate" '.annotations["io.github.minimillionaire.cleanup-tag"] = $tag' \
    "$scratch/original.json" > "$scratch/temporary.json"
  if [[ "$candidate_digest" == "$digest" ]]; then
    oras manifest push "$repository:$candidate" "$scratch/temporary.json" --media-type "$media_type" \
      --registry-config "$scratch/registry.json" >/dev/null
  else
    oras manifest fetch "$repository@$candidate_digest" --registry-config "$scratch/registry.json" | \
      jq -S . > "$scratch/resumed.json"
    cmp -s "$scratch/temporary.json" "$scratch/resumed.json" || {
      printf 'Candidate differs from the accepted image: %s\n' "$candidate" >&2; exit 1;
    }
  fi
  temporary_digest=$(oras resolve "$repository:$candidate" --registry-config "$scratch/registry.json")
  [[ "$temporary_digest" =~ ^sha256:[0-9a-f]{64}$ && "$temporary_digest" != "$digest" ]] || exit 1
  id=
  for _attempt in 1 2 3 4 5 6; do
    gh api --paginate "$endpoint?per_page=100" > "$scratch/current.json"
    id=$(jq -rs --arg digest "$temporary_digest" --arg candidate "$candidate" '
      add | map(select(.name == $digest)) |
      if length == 1 and .[0].metadata.container.tags == [$candidate] then .[0].id else empty end
    ' "$scratch/current.json")
    [[ -z "$id" ]] || break
    sleep 2
  done
  [[ "$id" =~ ^[0-9]+$ ]] || { printf 'Cannot isolate candidate: %s\n' "$candidate" >&2; exit 1; }
  [[ $(oras resolve "$repository:$candidate" --registry-config "$scratch/registry.json") == "$temporary_digest" ]] || exit 1
  [[ $(oras resolve "$published" --registry-config "$scratch/anonymous.json") == "$digest" ]] || exit 1
  gh api --method DELETE "$endpoint/$id"
  [[ $(oras resolve "$published" --registry-config "$scratch/anonymous.json") == "$digest" ]] || exit 1
  gh api --paginate "$endpoint?per_page=100" | jq -es --arg candidate "$candidate" \
    'add | all(.[]; (.metadata.container.tags | index($candidate)) == null)' >/dev/null
  printf 'Removed candidate tag: %s\n' "$candidate"
done < "$scratch/candidates.txt"
