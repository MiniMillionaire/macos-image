#!/bin/bash
set -euo pipefail
sw_vers
[[ $(sw_vers -productVersion) == "$EXPECTED_VERSION" ]]
[[ $(sw_vers -buildVersion) == "$EXPECTED_BUILD" ]]
[[ $(id -un) == admin ]]
[[ $(sudo -n id -u) == 0 ]]
[[ $(stat -f %Su /dev/console) == admin ]]
dseditgroup -o checkmember -m admin admin
sudo -n launchctl print system/com.openssh.sshd
sudo -n launchctl print system/com.apple.screensharing
[[ $(xcode-select -p) == /Library/Developer/CommandLineTools ]]
xcrun --sdk macosx --show-sdk-version
xcrun --sdk macosx --show-sdk-build-version
xcrun clang --version
xcrun swift --version
sdk=$(xcrun --sdk macosx --show-sdk-version)
[[ "${sdk%%.*}" == "${EXPECTED_VERSION%%.*}" ]]
[[ ! -e /Applications/Xcode.app ]]
scratch=$(mktemp -d /tmp/miso-acceptance.XXXXXX)
trap 'rm -rf "$scratch"' EXIT
cat > "$scratch/smoke.c" <<'EOF'
#include <assert.h>
#include <stdint.h>
int main(void) {
    uint64_t value = UINT64_C(0x123456789abcdef0);
    assert((value >> 32) == UINT64_C(0x12345678));
    return 0;
}
EOF
xcrun clang -Wall -Wextra -Werror "$scratch/smoke.c" -o "$scratch/c-smoke"
"$scratch/c-smoke"
cat > "$scratch/smoke.swift" <<'EOF'
import Foundation
struct Payload: Codable, Equatable { let message: String; let count: Int }
let expected = Payload(message: "MISO", count: 27)
let encoded = try JSONEncoder().encode(expected)
let actual = try JSONDecoder().decode(Payload.self, from: encoded)
precondition(actual == expected)
print("Swift Foundation round-trip passed")
EOF
xcrun swiftc "$scratch/smoke.swift" -o "$scratch/swift-smoke"
"$scratch/swift-smoke"
printf '%s\n' 'MISO_GUEST_ACCEPTANCE_PASSED'
