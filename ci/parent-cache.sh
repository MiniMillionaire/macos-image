#!/usr/bin/env bash

parent_cache_root="$HOME/.cache/macos-image/parents/minimillionaire-macos-image"
parent_cache_limit_kib=$((64 * 1024 * 1024))
parent_cache_limit_entries=2

parent_cache_init() {
  local ancestor
  for ancestor in "$HOME/.cache" "$HOME/.cache/macos-image" "$HOME/.cache/macos-image/parents" "$parent_cache_root"; do
    [[ ! -L "$ancestor" ]] || ci_die "Parent cache path contains a symbolic link"
  done
  if [[ ! -e "$parent_cache_root" ]]; then
    (umask 077; mkdir -p "$parent_cache_root")
  fi
  [[ -d "$parent_cache_root" && $(stat -f '%u' "$parent_cache_root") == "$(id -u)" &&
     $(stat -f '%Lp' "$parent_cache_root") == 700 ]] || ci_die "Invalid parent cache directory"
  if [[ ! -s "$parent_cache_root/.owner" && ! -L "$parent_cache_root/.owner" &&
        ( ! -e "$parent_cache_root/.owner" || -f "$parent_cache_root/.owner" ) &&
        -z $(find "$parent_cache_root" -mindepth 1 -maxdepth 1 ! -name .owner -print -quit) ]]; then
    (umask 077; printf '%s\n' "$repository" > "$parent_cache_root/.owner")
  fi
  [[ -f "$parent_cache_root/.owner" && ! -L "$parent_cache_root/.owner" &&
     $(cat "$parent_cache_root/.owner") == "$repository" ]] || ci_die "Parent cache ownership marker does not match"
  parent_cache_cleanup
}

parent_cache_cleanup() {
  local temporary name
  for temporary in "$parent_cache_root"/.incoming-*; do
    [[ -e "$temporary" || -L "$temporary" ]] || continue
    name=${temporary##*/}
    [[ "$name" =~ ^[.]incoming-[1-9][0-9]*-[1-9][0-9]*$ &&
       -d "$temporary" && ! -L "$temporary" ]] || ci_die "Invalid incomplete parent cache"
    [[ $(stat -f '%u' "$temporary") == "$(id -u)" &&
       $(stat -f '%Lp' "$temporary") == 700 &&
       -z $(find "$temporary" -type l -print -quit) ]] || ci_die "Invalid incomplete parent cache ownership"
    if [[ ! -s "$temporary/.digest" && ( ! -e "$temporary/.digest" || -f "$temporary/.digest" ) &&
          -z $(find "$temporary" -mindepth 1 -maxdepth 1 ! -name .digest -print -quit) ]]; then
      rm -f -- "$temporary/.digest"
      rmdir "$temporary"
      continue
    fi
    [[ -f "$temporary/.digest" && $(cat "$temporary/.digest") =~ ^sha256:[0-9a-f]{64}$ ]] ||
      ci_die "Invalid incomplete parent cache digest"
    rm -rf -- "$temporary"
  done
}

parent_cache_entry() {
  [[ "$1" =~ ^sha256:[0-9a-f]{64}$ ]] || ci_die "Invalid parent digest"
  printf '%s/sha256-%s\n' "$parent_cache_root" "${1#sha256:}"
}

parent_cache_require_entry() {
  local entry=$1
  local name=${1##*/}
  [[ "$entry" == "$parent_cache_root/$name" && "$name" =~ ^sha256-[0-9a-f]{64}$ ]] ||
    ci_die "Invalid parent cache entry path"
  [[ -d "$entry" && ! -L "$entry" && -f "$entry/.digest" && ! -L "$entry/.digest" &&
     $(cat "$entry/.digest") == "sha256:${name#sha256-}" ]] || ci_die "Parent cache entry is not owned"
  [[ $(stat -f '%u' "$entry") == "$(id -u)" ]] || ci_die "Parent cache entry belongs to another user"
  [[ -z $(find "$entry" -type l -print -quit) ]] || ci_die "Parent cache entry contains a symbolic link"
}

parent_cache_prune() {
  local minimum_kib=$1 keep=${2:-}
  local entry size count=0 total=0 available
  local entries=()
  while IFS= read -r entry; do
    [[ -n "$entry" ]] || continue
    parent_cache_require_entry "$entry"
    entries+=("$entry")
    size=$(du -sk "$entry" | awk '{print $1}')
    total=$((total + size))
    count=$((count + 1))
  done < <(
    for entry in "$parent_cache_root"/sha256-*; do
      [[ -e "$entry" || -L "$entry" ]] || continue
      stat -f '%m %N' "$entry"
    done | LC_ALL=C sort -n | cut -d' ' -f2-
  )
  (( count > 0 )) || return 0
  for entry in "${entries[@]}"; do
    available=$(df -Pk "$RUNNER_TEMP" | awk 'END {print $4}')
    if (( total <= parent_cache_limit_kib && count <= parent_cache_limit_entries && available >= minimum_kib )); then
      break
    fi
    [[ "$entry" != "$keep" ]] || continue
    size=$(du -sk "$entry" | awk '{print $1}')
    printf 'Removing parent cache: %s\n' "${entry##*/}"
    rm -rf -- "$entry"
    total=$((total - size))
    count=$((count - 1))
  done
}

parent_cache_store() {
  local source_layout=$1 digest=$2 entry temporary size
  parent_cache_init
  entry=$(parent_cache_entry "$digest")
  if [[ -e "$entry" || -L "$entry" ]]; then
    parent_cache_require_entry "$entry"
    rm -rf -- "$entry"
  fi
  size=$(du -sk "$source_layout" | awk '{print $1}')
  if (( size > parent_cache_limit_kib )); then
    printf 'Parent exceeds the cache limit; skipping cache: %s\n' "$digest"
    return
  fi
  temporary="$parent_cache_root/.incoming-$run_key"
  [[ ! -e "$temporary" && ! -L "$temporary" ]] || ci_die "Parent cache staging directory already exists"
  mkdir -m 0700 "$temporary"
  printf '%s\n' "$digest" > "$temporary/.digest"
  /bin/cp -cR "$source_layout" "$temporary/layout"
  mv "$temporary" "$entry"
  touch "$entry"
  parent_cache_prune 0 "$entry"
  printf 'Saved parent cache: %s\n' "$digest"
}

prepare_parent_source() {
  local variant reference digest entry metadata="$task_root/parent-image.json"
  local source_version=$MACOS_VERSION source_build=$MACOS_BUILD
  if [[ "$PACKAGE_FLAVOR" == slim ]]; then
    if [[ "$VARIANT" == xcode ]]; then
      variant=base
    else
      variant=$VARIANT
    fi
    reference="$REGISTRY/macos-$MACOS_FAMILY-$variant"
    digest=$(./scripts/registry resolve "$reference:$MACOS_VERSION")
  elif [[ -n "$VANILLA_SOURCE_PROFILE" ]]; then
    variant=vanilla
    reference="$REGISTRY/macos-$MACOS_FAMILY-$variant"
    digest=$VANILLA_SOURCE_DIGEST
    source_version=$VANILLA_SOURCE_VERSION
    source_build=$VANILLA_SOURCE_BUILD
  else
    variant=vanilla
    reference="$REGISTRY/macos-$MACOS_FAMILY-$variant"
    digest=$(./scripts/registry resolve "$reference:$MACOS_VERSION")
  fi
  entry=$(parent_cache_entry "$digest")
  parent_cache_credit_kib=0
  parent_cache_keep=
  if [[ -e "$entry" || -L "$entry" ]]; then
    parent_cache_require_entry "$entry"
    if inspect_layout "$entry/layout" "$metadata" &&
       [[ $(jq -er .manifest_digest "$metadata") == "$digest" ]]; then
      require_layout "$metadata" "$variant" "" "" "" "$source_version" "$source_build"
      parent_cache_credit_kib=$(du -sk "$entry" | awk '{print $1}')
      parent_cache_keep=$entry
      touch "$entry"
      printf 'Parent cache hit: %s@%s\n' "$reference" "$digest"
    else
      printf 'Discarding corrupt parent cache: %s\n' "$digest" >&2
      rm -rf -- "$entry"
    fi
  fi
  jq -n --arg reference "$reference@$digest" --arg digest "$digest" --arg variant "$variant" \
    --arg macos_version "$source_version" --arg macos_build "$source_build" \
    '{reference: $reference, digest: $digest, variant: $variant,
      macos_version: $macos_version, macos_build: $macos_build}' > "$task_root/parent-source.json"
}

restore_parent_source() {
  local destination=$1 metadata=$2 reference digest variant source_version source_build entry
  reference=$(jq -er .reference "$task_root/parent-source.json")
  digest=$(jq -er .digest "$task_root/parent-source.json")
  variant=$(jq -er .variant "$task_root/parent-source.json")
  source_version=$(jq -er .macos_version "$task_root/parent-source.json")
  source_build=$(jq -er .macos_build "$task_root/parent-source.json")
  entry=$(parent_cache_entry "$digest")
  [[ ! -e "$destination" && ! -L "$destination" ]] || ci_die "Parent destination already exists"
  if [[ -e "$entry" || -L "$entry" ]]; then
    parent_cache_require_entry "$entry"
    /bin/cp -cR "$entry/layout" "$destination"
  else
    printf 'Parent cache miss: %s\n' "$reference"
    ./scripts/registry download "$reference" "$destination"
  fi
  inspect_layout "$destination" "$metadata"
  require_layout "$metadata" "$variant" "" "" "" "$source_version" "$source_build"
  [[ $(jq -er .manifest_digest "$metadata") == "$digest" ]] || ci_die "Parent manifest digest changed"
  if [[ ! -d "$entry" ]]; then
    parent_cache_store "$destination" "$digest"
  else
    touch "$entry"
  fi
}
