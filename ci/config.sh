#!/usr/bin/env bash

ci_die() {
  echo "$*" >&2
  exit 1
}

ci_sha256() {
  shasum -a 256 "$1" | awk '{print $1}'
}

ci_version_key() {
  local value=$1
  local major
  local minor
  local patch
  IFS=. read -r major minor patch <<< "$value"
  printf '%s.%s.%s\n' "$major" "${minor:-0}" "${patch:-0}"
}

ci_read_value() {
  local file=$1
  local key=$2
  local line
  local value=

  while IFS= read -r line || [[ -n "$line" ]]; do
    if [[ "$line" == "$key="* ]]; then
      [[ -z "$value" ]] || ci_die "Duplicate $key in $file"
      value=${line#*=}
    fi
  done < "$file"

  [[ -n "$value" ]] || ci_die "Missing $key in $file"
  [[ "$value" != *[$'\t\r\n ']* ]] || ci_die "Invalid $key in $file"
  printf '%s\n' "$value"
}

ci_load_profile() {
  case ${PROFILE:-} in
    sequoia-15.6.1|sequoia-15.7.7|sequoia-15.7.8|sequoia-15.7.9|sequoia-15.8|tahoe-26.6.2|golden-gate-27.0) ;;
    *) ci_die "Unknown image profile: ${PROFILE:-}" ;;
  esac
  case ${VARIANT:-} in
    vanilla|base|xcode) ;;
    *) ci_die "Unknown image variant: ${VARIANT:-}" ;;
  esac

  CONFIG_PATH="config/$PROFILE.env"
  [[ -f "$CONFIG_PATH" && ! -L "$CONFIG_PATH" ]] || ci_die "Invalid profile file: $CONFIG_PATH"
  [[ -f config/toolchain.env && ! -L config/toolchain.env ]] || ci_die "Invalid toolchain configuration"

  MACOS_FAMILY=$(ci_read_value "$CONFIG_PATH" MACOS_FAMILY)
  MACOS_VERSION=$(ci_read_value "$CONFIG_PATH" MACOS_VERSION)
  MACOS_BUILD=$(ci_read_value "$CONFIG_PATH" MACOS_BUILD)
  IMAGE_PRERELEASE=$(ci_read_value "$CONFIG_PATH" IMAGE_PRERELEASE)
  IPSW_URL=
  IPSW_SIZE=
  IPSW_SHA256=
  INSTALLER_URL=
  INSTALLER_SIZE=
  INSTALLER_SHA256=
  VANILLA_SOURCE_PROFILE=
  VANILLA_SOURCE_DIGEST=
  VANILLA_SOURCE_VERSION=
  VANILLA_SOURCE_BUILD=
  VANILLA_SOURCE_CONFIG_SHA256=
  if grep -q '^VANILLA_SOURCE_PROFILE=' "$CONFIG_PATH"; then
    local source_config
    VANILLA_SOURCE_PROFILE=$(ci_read_value "$CONFIG_PATH" VANILLA_SOURCE_PROFILE)
    [[ "$VANILLA_SOURCE_PROFILE" =~ ^[a-z0-9][a-z0-9.-]*$ && "$VANILLA_SOURCE_PROFILE" != "$PROFILE" ]] ||
      ci_die "Invalid vanilla source profile"
    source_config="config/$VANILLA_SOURCE_PROFILE.env"
    [[ -f "$source_config" && ! -L "$source_config" ]] || ci_die "Invalid vanilla source configuration"
    [[ $(ci_read_value "$source_config" IMAGE_PRERELEASE) == false ]] ||
      ci_die "Vanilla source must be an official release"
    [[ $(ci_read_value "$source_config" IPSW_SHA256) =~ ^[0-9a-f]{64}$ ]] ||
      ci_die "Vanilla source must be built from a pinned IPSW"
    [[ $(ci_read_value "$source_config" MACOS_FAMILY) == "$MACOS_FAMILY" ]] ||
      ci_die "Vanilla source must use the same macOS family"
    VANILLA_SOURCE_VERSION=$(ci_read_value "$source_config" MACOS_VERSION)
    VANILLA_SOURCE_BUILD=$(ci_read_value "$source_config" MACOS_BUILD)
    [[ ${VANILLA_SOURCE_VERSION%%.*} == "${MACOS_VERSION%%.*}" ]] ||
      ci_die "Vanilla source must use the same macOS major"
    VANILLA_SOURCE_CONFIG_SHA256=$(ci_sha256 "$source_config")
    VANILLA_SOURCE_DIGEST=$(ci_read_value "$CONFIG_PATH" VANILLA_SOURCE_DIGEST)
    INSTALLER_URL=$(ci_read_value "$CONFIG_PATH" INSTALLER_URL)
    INSTALLER_SIZE=$(ci_read_value "$CONFIG_PATH" INSTALLER_SIZE)
    INSTALLER_SHA256=$(ci_read_value "$CONFIG_PATH" INSTALLER_SHA256)
    grep -Eq '^IPSW_(URL|SIZE|SHA256)=' "$CONFIG_PATH" && ci_die "Upgrade profile must not specify an IPSW"
  else
    IPSW_URL=$(ci_read_value "$CONFIG_PATH" IPSW_URL)
    IPSW_SIZE=$(ci_read_value "$CONFIG_PATH" IPSW_SIZE)
    IPSW_SHA256=$(ci_read_value "$CONFIG_PATH" IPSW_SHA256)
  fi
  MINIMUM_HOST_MAJOR=$(ci_read_value "$CONFIG_PATH" MINIMUM_HOST_MAJOR)

  TART_VERSION=$(ci_read_value config/toolchain.env TART_VERSION)
  PACKER_VERSION=$(ci_read_value config/toolchain.env PACKER_VERSION)
  GO_VERSION=$(ci_read_value config/toolchain.env GO_VERSION)
  PACKER_TART_PLUGIN_VERSION=$(ci_read_value config/toolchain.env PACKER_TART_PLUGIN_VERSION)
  SWIFT_VERSION=$(ci_read_value config/toolchain.env SWIFT_VERSION)

  [[ "$MACOS_FAMILY" =~ ^[a-z0-9][a-z0-9.-]*$ ]] || ci_die "Invalid macOS family"
  [[ "$MACOS_VERSION" =~ ^[0-9]+([.][0-9]+){1,2}$ ]] || ci_die "Invalid macOS version"
  [[ "$MACOS_BUILD" =~ ^[0-9A-Z]+$ ]] || ci_die "Invalid macOS build"
  [[ "$IMAGE_PRERELEASE" == true || "$IMAGE_PRERELEASE" == false ]] || ci_die "Invalid prerelease value"
  if [[ -n "$VANILLA_SOURCE_PROFILE" ]]; then
    [[ "$VANILLA_SOURCE_VERSION" =~ ^[0-9]+([.][0-9]+){1,2}$ && "$VANILLA_SOURCE_BUILD" =~ ^[0-9A-Z]+$ ]] ||
      ci_die "Invalid vanilla source version or build"
    [[ "$VANILLA_SOURCE_DIGEST" =~ ^sha256:[0-9a-f]{64}$ ]] || ci_die "Invalid vanilla source digest"
    [[ "$INSTALLER_URL" == https://swcdn.apple.com/content/downloads/* ]] || ci_die "Invalid installer URL"
    [[ "$INSTALLER_SIZE" =~ ^[1-9][0-9]*$ ]] || ci_die "Invalid installer size"
    [[ "$INSTALLER_SHA256" =~ ^[0-9a-f]{64}$ ]] || ci_die "Invalid installer SHA-256"
  else
    [[ "$IPSW_URL" == https://updates.cdn-apple.com/* ]] || ci_die "Invalid IPSW URL"
    [[ "$IPSW_SIZE" =~ ^[1-9][0-9]*$ ]] || ci_die "Invalid IPSW size"
    [[ "$IPSW_SHA256" =~ ^[0-9a-f]{64}$ ]] || ci_die "Invalid IPSW SHA-256"
  fi
  [[ "$MINIMUM_HOST_MAJOR" =~ ^[1-9][0-9]*$ ]] || ci_die "Invalid host version"
  for version in "$TART_VERSION" "$PACKER_VERSION" "$GO_VERSION" "$PACKER_TART_PLUGIN_VERSION" "$SWIFT_VERSION"; do
    [[ "$version" =~ ^[0-9]+([.][0-9]+){1,2}$ ]] || ci_die "Invalid tool version: $version"
  done

  UPDATE_LATEST=${UPDATE_LATEST:-false}
  [[ "$UPDATE_LATEST" == true || "$UPDATE_LATEST" == false ]] || ci_die "Invalid update-latest value"
  [[ "$UPDATE_LATEST" == false || "$IMAGE_PRERELEASE" == false ]] ||
    ci_die "Prerelease macOS images cannot update latest"
  if [[ "$VARIANT" == xcode ]]; then
    [[ ${XCODE_VERSION:-} =~ ^(0|[1-9][0-9]*)[.](0|[1-9][0-9]*)([.](0|[1-9][0-9]*))?$ ]] || ci_die "Xcode images require an exact Xcode version"
    XCODE_TAG=${XCODE_TAG:-$XCODE_VERSION}
    [[ ${#XCODE_TAG} -le 128 ]] || ci_die "Xcode tag is too long"
    [[ "$XCODE_TAG" =~ ^(0|[1-9][0-9]*)([.](0|[1-9][0-9]*)){0,2}(-[a-z0-9]+([.-][a-z0-9]+)*)?$ ]] ||
      ci_die "Invalid Xcode tag"
    [[ $(ci_version_key "${XCODE_TAG%%-*}") == "$(ci_version_key "$XCODE_VERSION")" ]] ||
      ci_die "Xcode tag does not match the Xcode version"
    if [[ "$XCODE_TAG" =~ ^(0|[1-9][0-9]*)([.](0|[1-9][0-9]*)){0,2}$ ]]; then
      XCODE_PRERELEASE=false
    else
      XCODE_PRERELEASE=true
      [[ "$UPDATE_LATEST" == false ]] || ci_die "Prerelease Xcode tags cannot update latest"
    fi
    VARIANT_ID="xcode-$XCODE_TAG"
  else
    [[ -z ${XCODE_VERSION:-} ]] || ci_die "Xcode version applies only to Xcode images"
    [[ -z ${XCODE_TAG:-} ]] || ci_die "Xcode tag applies only to Xcode images"
    XCODE_TAG=
    XCODE_PRERELEASE=false
    VARIANT_ID=$VARIANT
  fi

  [[ ${REGISTRY:-} == ghcr.io/minimillionaire ]] || ci_die "Unexpected registry: ${REGISTRY:-}"
  PACKAGE_FLAVOR=${PACKAGE_FLAVOR:-standard}
  case "$PACKAGE_FLAVOR" in
    standard) PACKAGE_FAMILY=$MACOS_FAMILY ;;
    slim)
      [[ "$PROFILE" == golden-gate-27.0 ]] || ci_die "Slim publication requires the Golden Gate profile"
      PACKAGE_FAMILY=$MACOS_FAMILY-slim
      ;;
    *) ci_die "Unknown package flavor: $PACKAGE_FLAVOR" ;;
  esac
  PACKAGE_REF="$REGISTRY/macos-$PACKAGE_FAMILY-$VARIANT:$MACOS_VERSION"
  LATEST_REF=
  RELEASE_TAG=
  if [[ "$VARIANT" == xcode ]]; then
    PACKAGE_REF="$REGISTRY/macos-$PACKAGE_FAMILY-xcode:$MACOS_VERSION-xcode$XCODE_TAG"
    RELEASE_TAG="$MACOS_VERSION-xcode$XCODE_TAG"
    [[ ${#RELEASE_TAG} -le 128 ]] || ci_die "Combined macOS and Xcode tag is too long"
  fi
  [[ "$UPDATE_LATEST" == false ]] || LATEST_REF="$REGISTRY/macos-$PACKAGE_FAMILY-$VARIANT:latest"
  PROFILE_CONFIG_SHA256=$(ci_sha256 "$CONFIG_PATH")
  TOOLCHAIN_CONFIG_SHA256=$(ci_sha256 config/toolchain.env)
}

ci_write_output() {
  local name=$1
  local value=$2
  [[ -n ${GITHUB_OUTPUT:-} ]] || ci_die "GITHUB_OUTPUT is not set"
  printf '%s=%s\n' "$name" "$value" >> "$GITHUB_OUTPUT"
}
