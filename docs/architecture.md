# Architecture

## Build flow

Tart creates the VM from a pinned Apple restore image. A small VNC controller completes Setup Assistant, then Packer owns SSH provisioning and validation. This separates version-specific screen input from the repeatable provisioning stages.

Provisioning uses small shell scripts instead of Ansible. This keeps local setup light, makes each stage directly runnable, and leaves failed VMs available for inspection.

Checks run against disposable clones. Templates retain the recovery partition, except Xcode builds, which relocate it while expanding the disk.

## Setup Assistant

macOS 15 and 26 do not support the Virtualization framework guest provisioning API. Their vanilla images use fixed keyboard and pointer sequences for a fixed virtual display. The macOS 15 flow restarts between account creation, Setup Assistant completion, sharing, and security configuration to reset UI focus. Installation finalization and boot waits are configurable for different host speeds.

Tart receives isolated `en_US` preferences during installation and first boot. This keeps the language chooser independent of the build host's language and region without modifying the host preferences.

Screenshots may be used to map a new macOS version during development. Production and CI builds neither capture nor interpret the screen, and do not use OCR.

macOS 27 supports `VZMacGuestProvisioningOptions`. Its image should pass account, automatic login, and remote login settings through Tart instead of automating Setup Assistant.

Daily base and Xcode builds clone a validated vanilla image and use SSH only. Vanilla rebuilds are reserved for macOS restore-image changes.

## Versioning

Every restore image is pinned by version, build, and Apple CDN URL. A build fails if the installed version or build differs.

Apple did not publish a UniversalMac restore IPSW for macOS 15.7. A 15.7 image therefore requires a separate, same-major update stage from the 15.6.1 restore image. That stage must select macOS 15 update labels explicitly and verify the resulting build before publication.

## Artifacts

Tart pushes VM images as OCI artifacts. Each variant uses a separate package name and an immutable version tag. Builds add OCI revision and version labels.
