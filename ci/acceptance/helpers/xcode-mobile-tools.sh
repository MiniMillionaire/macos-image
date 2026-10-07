#!/bin/bash
set -euo pipefail
source "$HOME/.zprofile"
export HOMEBREW_NO_AUTO_UPDATE=1 HOMEBREW_NO_ANALYTICS=1
export CI=true FLUTTER_SUPPRESS_ANALYTICS=true
configuration=/private/tmp/offline-xcode-config.json
expected() { jq -er --arg tool "$1" '.versions[$tool]' "$configuration"; }
test "$(tuist version)" = "$(expected tuist)"
for tool in xcodes applesimutils carthage pod fastlane xcpretty codex claude kiro-cli sdkmanager flutter dart java; do
  command -v "$tool"
done
require_version() {
  local version=$1 output pattern
  shift
  output=$("$@")
  printf '%s\n' "$output"
  pattern="(^|[^[:digit:].])${version//./\.}([^[:digit:].]|$)"
  [[ "$output" =~ $pattern ]]
}
xcodes version
require_version "$(expected applesimutils)" applesimutils --version
applesimutils --help
carthage version
require_version "$(expected cocoapods)" pod --version
require_version "$(expected fastlane)" fastlane --version
require_version "$(expected xcpretty)" xcpretty --version
require_version "$(expected codex)" codex --version
require_version "$(expected claude-code)" claude --version
require_version "$(expected kiro-cli)" kiro-cli --version
java -version
sdkmanager --sdk_root="$ANDROID_HOME" --list_installed
licenses=$(sdkmanager --sdk_root="$ANDROID_HOME" --licenses </dev/null)
printf '%s\n' "$licenses"
grep -Fq 'All SDK package licenses accepted.' <<< "$licenses"
flutter --version --machine | jq -e --argjson expected "$(jq .flutter "$configuration")" 'contains($expected)'
doctor=$(flutter doctor -v </dev/null)
printf '%s\n' "$doctor"
if grep -Eiq 'Android licenses not accepted|license status unknown' <<< "$doctor"; then exit 1; fi
work=$(mktemp -d /private/tmp/miso-dart-acceptance.XXXXXXXX)
case "$work" in /private/tmp/miso-dart-acceptance.*) ;; *) exit 64 ;; esac
trap 'rm -rf "$work"' EXIT
cat > "$work/check.dart" <<'DART'
int factorial(int n) => n < 2 ? 1 : n * factorial(n - 1);
void main(List<String> args) {
  if (factorial(int.parse(args.single)) != 720) throw StateError('failed');
  print('dart-test-ok');
}
DART
test "$(dart --disable-dart-dev "$work/check.dart" 6)" = dart-test-ok
dart compile exe "$work/check.dart" -o "$work/check"
test "$("$work/check" 6)" = dart-test-ok
require_version "$(jq -er '.android["platform-tools"]' "$configuration")" adb version
printf 'int miso_answer(void) { return 42; }\n' > "$work/check.c"
ndk_version=$(jq -er '.android | to_entries[] | select(.key | startswith("ndk;")) | .value' "$configuration")
ndk="$ANDROID_HOME/ndk/$ndk_version/toolchains/llvm/prebuilt/darwin-x86_64/bin"
"$ndk/clang" --target=aarch64-linux-android24 -shared -fPIC "$work/check.c" -o "$work/libcheck.so"
"$ndk/llvm-readelf" --file-header "$work/libcheck.so" | grep AArch64
printf 'ANDROID_ADB=passed NDK_COMPILE=passed\n'
printf 'MOBILE_TOOLS=passed\n'
