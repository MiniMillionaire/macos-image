# Architecture

## Host interface

The primary host interface is the compiled Swift `macos-image` command. The
Swift package separates the executable from `MacOSImageCore`, which owns the
typed operation model, repository discovery, and subprocess lifecycle. This
keeps command parsing out of the build logic and allows a future SwiftUI target
to consume the same core.

The Swift CLI currently delegates operations to `scripts/image`. The shell
backend retains the validated Tart, Packer, and VNC sequencing behavior while
the host orchestration migrates incrementally. The Go VNC controller is also
kept intact until a replacement passes the same version-pinned clean builds and
independent reboot checks.

## Build flow

Tart creates the VM from a pinned Apple restore image. A small VNC controller completes Setup Assistant, then Packer owns SSH provisioning and validation. This separates version-specific screen input from the repeatable provisioning stages.

Provisioning uses small shell scripts instead of Ansible. This keeps local setup light, makes each stage directly runnable, and leaves failed VMs available for inspection.

Checks run against disposable clones. Templates retain the Recovery partition
and relocate it when expanding the disk.

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
initial language migration to complete in the actual user plist before writing
typed preferences; a defaults query can return an inherited schema value early.
A fixed VNC phase requests and confirms the Gatekeeper change in the same boot.
Both macOS 26 and 27 then use the same SSH-only
vanilla provisioning template. See [macOS 27](macos-27.md) for the pinned restore
image and the observed native API behavior.

Base builds clone a validated vanilla image; Xcode builds clone a validated base
image. Both use SSH provisioning. Vanilla rebuilds are reserved for macOS
restore-image changes.

Guest scripts run with Apple's Bash 3.2. A failing standalone `[[ ... ]]`
condition does not trigger `set -e` in that shell. Assertions use `test` or an
explicit failure branch so that wrong versions and missing prerequisites stop
the build. Validation exercises these guards with mocked system commands under
`/bin/bash`. The Command Line Tools installer accepts both the older `Xcode-...`
labels and current `Xcode ...` labels and rejects a missing label before calling
the installer.

## Versioning

Every restore image is pinned by version, build, Apple CDN URL, size, and SHA-256.
The download is verified before Tart starts. A build fails if the installed
version or build differs. The source commit identifies the recipe; the OCI
manifest digest identifies the built image.

An upgrade target starts from the nearest preceding official IPSW in the same
macOS major version. Its verified vanilla image is pinned by digest. Each
target upgrades directly from that image until a newer official IPSW provides
the next starting point; patch images are not chained together. Sequoia 15.7.7
through 15.8 therefore start from the 15.6.1 vanilla image. Installer versions,
builds, sizes, and checksums are pinned separately from the source image.

The [update procedure](macos-updates.md) covers the build policy, exact full
installers, and selection of the latest release within the guest's current
major. CI builds and verifies each target before publication. Local clones are
used to investigate failures and do not replace the CI acceptance path.

## Artifacts

Tart exports its native OCI manifest and blobs through a loopback registry into
an OCI image layout. ORAS copies that layout to the remote registry without
changing the manifest or blob contents. Public GHCR downloads use bounded range
requests and verify each blob before importing the layout. The adapter is part
of the existing Go module and has no third-party dependencies. Completed blobs
are retained with the verified build after an interrupted download, so a
recovery run can verify and reuse them.

Package names follow Cirrus: `macos-<family>-vanilla`, `macos-<family>-base`, and
`macos-<family>-xcode`. Vanilla/base use their macOS version as the primary tag;
`latest` points to the verified current release within each major version. Xcode
uses its version as the tag. Labels record the source commit, repository, macOS
version/build, and variant. Xcode images also record their installed Xcode
version. Tags can be updated after a rebuild; consumers pin a digest for exact
bytes.

The release workflow verifies a fresh clone before uploading by digest, then
downloads the full image anonymously, imports it, and checks another cold boot.
Only then does it update the version or latest tag. Xcode publications are
recorded in a GitHub Release named for their Xcode tag. Recovery preserves the original export:
Tart includes an upload timestamp in its manifest, so exporting the same VM again
does not preserve its digest. See [Releases](releases.md).
