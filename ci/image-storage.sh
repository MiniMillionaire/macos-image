#!/bin/bash

image_storage_paths() {
  IMAGE_BUILD_WORKSPACE="$RUNNER_TEMP/offline-image"
  IMAGE_ACCEPTANCE_WORKSPACE="$RUNNER_TEMP/acceptance-$GITHUB_RUN_ID-$GITHUB_RUN_ATTEMPT"
  IMAGE_CACHE_ROOT="$HOME/.cache/macos-image"
  [[ -n ${IMAGE_STORAGE_DIRECTORY:-} ]] || return 0

  local directory=$IMAGE_STORAGE_DIRECTORY device info mount
  [[ "$directory" == /* && "$directory" != *$'\n'* && "$directory" != *$'\r'* &&
    -d "$directory" && -w "$directory" && ! -L "$directory" ]] || {
    printf '%s\n' 'Storage directory must already exist and be writable.' >&2
    return 1
  }
  directory=$(cd "$directory" && pwd -P) || return 1
  [[ "$directory" != / && "$GITHUB_RUN_ID" =~ ^[0-9]+$ && "$GITHUB_RUN_ATTEMPT" =~ ^[0-9]+$ ]] || return 1
  device=$(df -P "$directory" | awk 'NR == 2 {print $1}')
  info=$(diskutil info -plist "$device" | plutil -convert json -o - -) || return 1
  [[ $(jq -r .FilesystemType <<< "$info") == apfs ]] || {
    printf '%s\n' 'Storage directory must be on APFS for sparse images and clones.' >&2
    return 1
  }
  mount=$(jq -er .MountPoint <<< "$info") || return 1
  if [[ "$directory" == /Volumes/* && "$mount" != /Volumes/* ]]; then
    printf '%s\n' 'The requested storage volume is not mounted.' >&2
    return 1
  fi
  IMAGE_BUILD_WORKSPACE="$directory/macos-image/runs/$GITHUB_RUN_ID-$GITHUB_RUN_ATTEMPT/build"
  IMAGE_ACCEPTANCE_WORKSPACE="$directory/macos-image/runs/$GITHUB_RUN_ID-$GITHUB_RUN_ATTEMPT/acceptance"
  IMAGE_CACHE_ROOT="$directory/macos-image/cache"
}

image_storage_require_directory() {
  local directory=$1 path=$1
  [[ "$directory" == /* ]] || return 1
  while [[ "$path" != / ]]; do
    [[ ! -L "$path" ]] || {
      printf 'Storage path is a symbolic link: %s\n' "$path" >&2
      return 1
    }
    path=$(dirname "$path")
  done
  (umask 077; mkdir -p "$directory") || return 1
  [[ $(stat -f %u "$directory") == "$(id -u)" ]] || return 1
}

image_storage_require_same_volume() {
  [[ $(stat -f %d "$1") == "$(stat -f %d "$2")" ]] || {
    printf '%s\n' 'Image workspace and cache must be on the same volume.' >&2
    return 1
  }
}

image_storage_validate_ipsw() {
  [[ -n ${LOCAL_IPSW_PATH:-} ]] || return 0
  [[ ${BUILD_RUNNER_SELECTION:-default} == local &&
    ${BUILD_RUNNER_ENVIRONMENT:-} == self-hosted && -z ${PARENT_RUN:-} &&
    ${TARGET_VARIANT:-} != xcode ]] || return 1
  local path=$LOCAL_IPSW_PATH directory
  [[ -d ${RUNNER_TEMP:-} ]] || return 1
  [[ "$path" == /*.ipsw && "$path" != *$'\n'* && "$path" != *$'\r'* &&
    "$path" != *$'\t'* && -f "$path" && -r "$path" && ! -L "$path" ]] || return 1
  directory=$(cd "$(dirname "$path")" && pwd -P) || return 1
  [[ "$path" == "$directory/$(basename "$path")" ]] || return 1
  while :; do
    [[ ! "$directory" -ef "$RUNNER_TEMP" && ! "$directory" -ef "$IMAGE_BUILD_WORKSPACE" ]] || return 1
    [[ "$directory" != / ]] || break
    directory=$(dirname "$directory")
  done
}
