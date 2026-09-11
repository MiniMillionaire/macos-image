# Architecture

## Build flow

Tart creates the VM from a pinned Apple restore image. A small VNC controller completes Setup Assistant, then Packer owns SSH provisioning and validation. This separates version-specific screen input from the repeatable provisioning stages.

Provisioning uses small shell scripts instead of Ansible. This keeps local setup light, makes each stage directly runnable, and leaves failed VMs available for inspection.

Checks run against disposable clones. Templates retain the recovery partition, except Xcode builds, which relocate it while expanding the disk.

## Setup Assistant

macOS 15 and 26 do not support the Virtualization framework guest provisioning API. Their vanilla images use fixed keyboard and pointer sequences for a fixed virtual display. The macOS 15 flow restarts between account creation, Setup Assistant completion, sharing, and security configuration to reset UI focus. macOS 26 also has a separate user setup phase after the system terms and first login. Each VNC phase has a 30-minute deadline, and connection establishment has a 30-second deadline. Installation finalization and boot waits are configurable for different host speeds.

Tart receives isolated `en_US` preferences during installation and first boot. This keeps the language chooser independent of the build host's language and region without modifying the host preferences.

Both flows reset the language list with Home and select standard English.
Tahoe explicitly selects United States in the country list and confirms the
English (US) language and U.S. input source page. Its fixed pointer coordinates
use a 2048 by 1536 framebuffer with Tart configured for a 1024 by 768 display and
display refitting disabled. The guest's timezone is set to GMT over SSH.

Verification checks the exact OS version and build, completed Setup Assistant,
account and full name, `en_US`, `en-US`, a U.S./ABC keyboard, GMT, disabled
VoiceOver and Gatekeeper, automatic login, and Command Line Tools. Tests boot a
fresh clone so that persistence is checked independently of the provisioning
session.

Screenshots may be used to map a new macOS version during development. Production and CI builds neither capture nor interpret the screen, and do not use OCR.

On the macOS 27 host, VNC initially advertises a temporary 1280 by 720 display.
Keyboard input works in that state, but pointer events are scaled using those
dimensions. After the boot wait, the controller sends a zero-area update request
and confirms the configured display dimensions within 30 seconds before sending
input. Production uses only display-size metadata. Tart also sends a raw pixel
payload after resizing; the controller discards those bytes without decoding,
storing, or inspecting them. Development screen captures had hidden the
missing size synchronization by completing it implicitly.

macOS 27 uses `VZMacGuestProvisioningOptions` through Tart for the account,
automatic login, and SSH. The native API leaves the guest's language and keyboard
preferences unset, so an SSH stage explicitly selects `en_US`, `en-US`, and the
U.S. keyboard before restarting. That stage waits for the native account's
initial language migration to complete before writing typed preferences.
A fixed VNC phase requests and confirms the Gatekeeper change in the same boot.
Both macOS 26 and 27 then use the same SSH-only
vanilla provisioning template. See [macOS 27](macos-27.md) for the pinned RC and
the observed native API behavior.

Daily base and Xcode builds clone a validated vanilla image and use SSH only. Vanilla rebuilds are reserved for macOS restore-image changes.

Guest scripts run with Apple's Bash 3.2. A failing standalone `[[ ... ]]`
condition does not trigger `set -e` in that shell. Assertions use `test` or an
explicit failure branch so that wrong versions and missing prerequisites stop
the build. Validation exercises these guards with mocked system commands under
`/bin/bash`. The Command Line Tools installer accepts both the older `Xcode-...`
labels and current `Xcode ...` labels and rejects a missing label before calling
the installer.

## Versioning

Every restore image is pinned by version, build, and Apple CDN URL. A build fails if the installed version or build differs.

Apple did not publish a UniversalMac restore IPSW for macOS 15.7. A 15.7 image therefore requires a separate, same-major update stage from the 15.6.1 restore image. That stage must select macOS 15 update labels explicitly and verify the resulting build before publication.

## Artifacts

Tart pushes VM images as OCI artifacts. Each variant uses a separate package name and an immutable version tag. Builds add OCI revision and version labels.
