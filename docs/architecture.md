# Architecture

## Build engine

Packer remains the build engine because the Tart builder owns VM startup, screen input, SSH readiness, shutdown, and error reporting. Replacing it with shell orchestration would duplicate those lifecycle controls without removing the macOS Setup Assistant constraint.

Provisioning uses small shell scripts instead of Ansible. This keeps local setup light, makes each stage directly runnable, and leaves failed VMs available for inspection.

## Setup Assistant

macOS 15 and 26 do not support the Virtualization framework guest provisioning API. Their vanilla images use the Tart Packer plugin's screen automation. Text recognition is used where the plugin can identify a stable screen label; the remaining keyboard sequences are isolated in one template per macOS major version.

macOS 27 supports `VZMacGuestProvisioningOptions`. Its image should pass account, automatic login, and remote login settings through Tart instead of automating Setup Assistant.

Daily base and Xcode builds clone a validated vanilla image and use SSH only. Vanilla rebuilds are reserved for macOS restore-image changes.

## Versioning

Every restore image is pinned by version, build, and Apple CDN URL. A build fails if the installed version or build differs.

Apple did not publish a UniversalMac restore IPSW for macOS 15.7. A 15.7 image therefore requires a separate, same-major update stage from the 15.6.1 restore image. That stage must select macOS 15 update labels explicitly and verify the resulting build before publication.

## Artifacts

Tart pushes VM images as OCI artifacts. Each variant uses a separate package name and an immutable version tag. Builds add OCI revision and version labels.

