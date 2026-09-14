# macOS 26 vanilla validation

The clean macOS 26.6.2 (25G83) build and independent clone/reboot verification
passed on September 11, 2026. The host was an Apple M4 Pro with 24 GiB of memory,
running macOS 27.0 (26A5425a).

The build used Tart 2.36.0, Packer 1.16.0, Go 1.25.0, and Tart Packer plugin
1.21.0. The implementation revision was `e44205d`. The verification template
also imposed a five-minute shell provisioner limit.

## Commands and artifacts

```sh
IMAGE_CONFIG=config/tahoe-26.6.2.env ./scripts/image build vanilla 90s macos-tahoe-26.6.2-clean-e2e-20260911-04
IMAGE_CONFIG=config/tahoe-26.6.2.env ./scripts/image import vanilla macos-tahoe-26.6.2-clean-e2e-20260911-04 macos-tahoe-26.6.2-verify-20260911-04
```

The build completed with exit status 0 in 1,624 seconds. The clone verification
completed with exit status 0 in 25 seconds. The source VM was stopped after
validation and later removed after fresh CI publication passed.
The verification clone was deleted later at the user's request, together with
the failed builds and temporary debugging VMs. The validation logs remain.
The build had a two-hour external process deadline; verification had a
15-minute deadline. The build and verification did not overwrite or delete
existing VMs.

Local logs:

- `/tmp/macos-image-26-clean-e2e-20260911-04.log`
- `/tmp/macos-image-26-verify-20260911-04.log`

The build started from the pinned Apple IPSW, completed all five fixed VNC
phases, and finished Packer provisioning without manual repair. It confirmed
the 2048 by 1536 VNC dimensions before each phase. No screenshots, OCR, or image
interpretation were used. The host Keychain was not accessed.

## Checks after clone and reboot

| Check | Verified value |
| --- | --- |
| macOS version and build | 26.6.2, 25G83 |
| Architecture | arm64 |
| Account and full name | admin, admin |
| SSH development password | admin |
| Locale and preferred language | en_US, en-US |
| Keyboard layout | U.S. |
| Timezone | GMT |
| Automatic console login | admin |
| Setup Assistant | Completed and not running |
| VoiceOver | Not running |
| Gatekeeper | assessments disabled |
| Command Line Tools | Xcode 26.6, active developer directory and clang found |

The installed update label was `Command Line Tools for Xcode 26.6-26.6`.
The active developer directory was `/Library/Developer/CommandLineTools`, and
`xcrun --find clang` returned its `usr/bin/clang` executable.

## Corrections established during validation

- VNC initially used a temporary display size for pointer scaling. Controlled
  SSH observations established the cause, and the controller now confirms
  display dimensions before input. See [the measurements](vnc-display.md).
- The CLT parser now accepts Apple's current space-separated Xcode labels and
  rejects missing labels before installation.
- Guest assertions now fail correctly under Apple's Bash 3.2. Mocked regression
  checks verify early failure for missing labels and wrong versions/builds.

This record covers the vanilla image. Base and Xcode layers have separate
provisioning and verification workflows.
