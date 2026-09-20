#!/usr/bin/env bash
set -euo pipefail

root_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
test_dir=$(mktemp -d)
trap '/bin/rm -rf "$test_dir"' EXIT
mkdir "$test_dir/bin" "$test_dir/state"

cat > "$test_dir/bin/mock" <<'EOF'
#!/bin/bash
set -euo pipefail
case ${0##*/} in
  sw_vers)
    case $1 in
      -productVersion) echo 26.6.2 ;;
      -buildVersion) echo 25G83 ;;
    esac
    ;;
  uname|id|defaults)
    /usr/bin/touch "$MOCK_STATE/unexpected"
    echo arm64
    ;;
  xcode-select|xcrun)
    test -f "$MOCK_STATE/installed" || exit 1
    echo /mock/Developer
    ;;
  softwareupdate)
    case $1 in
      --list)
        if [[ -n ${MOCK_LABEL:-} ]]; then
          printf '* Label: %s\n' "$MOCK_LABEL"
        fi
        ;;
      --install)
        /usr/bin/touch "$MOCK_STATE/install-attempt"
        test -n "${2:-}"
        test "$2" = "$MOCK_LABEL"
        /usr/bin/touch "$MOCK_STATE/installed"
        ;;
    esac
    ;;
  sudo)
    if [[ $1 == softwareupdate ]]; then
      shift
      exec softwareupdate "$@"
    fi
    /usr/bin/touch "$MOCK_STATE/unexpected"
    exit 97
    ;;
  touch|rm) ;;
esac
EOF
chmod +x "$test_dir/bin/mock"
for command in sw_vers uname id defaults xcode-select xcrun softwareupdate sudo touch rm; do
  ln -s mock "$test_dir/bin/$command"
done

export PATH="$test_dir/bin:$PATH"
export MOCK_STATE="$test_dir/state"
export GUEST_USERNAME=admin GUEST_PASSWORD=admin IMAGE_PROFILE=invalid

expect_failure() {
  local status=0
  "$@" > "$test_dir/output" 2>&1 || status=$?
  if [[ $status != 1 || -e "$MOCK_STATE/unexpected" || -e "$MOCK_STATE/install-attempt" ]]; then
    cat "$test_dir/output" >&2
    echo "Expected an immediate failure with status 1; got $status" >&2
    exit 1
  fi
}

for label in 'Command Line Tools for Xcode-16.4' 'Command Line Tools for Xcode 26.6-26.6'; do
  MOCK_LABEL="$label" /bin/bash "$root_dir/scripts/guest/install-command-line-tools.sh" > "$test_dir/output"
  test -f "$MOCK_STATE/installed"
  /bin/rm "$MOCK_STATE/installed" "$MOCK_STATE/install-attempt"
done

expect_failure env MOCK_LABEL= /bin/bash "$root_dir/scripts/guest/install-command-line-tools.sh"
for script in configure-vanilla.sh prepare-native.sh; do
  expect_failure env EXPECTED_VERSION=0 EXPECTED_BUILD=25G83 /bin/bash "$root_dir/scripts/guest/$script"
  expect_failure env EXPECTED_VERSION=26.6.2 EXPECTED_BUILD=invalid /bin/bash "$root_dir/scripts/guest/$script"
done
expect_failure env IMAGE_PROFILE=vanilla EXPECTED_VERSION=0 EXPECTED_BUILD=25G83 /bin/bash "$root_dir/scripts/guest/verify-image.sh"
expect_failure env IMAGE_PROFILE=vanilla EXPECTED_VERSION=26.6.2 EXPECTED_BUILD=invalid /bin/bash "$root_dir/scripts/guest/verify-image.sh"
printf 'Guest script checks passed with %s\n' "$(/bin/bash --version | head -1)"
