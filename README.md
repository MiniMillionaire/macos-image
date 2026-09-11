# macOS images for Tart

This repository builds reproducible macOS virtual machine images for Tart. It supports a local-first workflow and OCI publication.

The current image definitions are:

| Configuration | Restore image | Local build host |
| --- | --- | --- |
| `sequoia-15.6.1` | macOS 15.6.1 (24G90) | macOS 15 or newer |
| `tahoe-26.6.2` | macOS 26.6.2 (25G83) | macOS 26 or newer |

The Tahoe vanilla image has passed a clean IPSW build and an independent
clone/reboot check on the macOS 27 host. See the
[validation record](docs/tahoe-validation.md).

## Requirements

- Apple silicon
- Tart 2.36 or newer
- Packer 1.14 or newer
- Go 1.25 or newer
- A local Xcode XIP archive for Xcode images

Packer installs the pinned Tart plugin with `packer init`.

The verified toolchain is Tart 2.36.0, Packer 1.16.0, Go 1.25.0, and the Tart
Packer plugin 1.21.0. See [Host setup](docs/host-setup.md) for the installation
record on the macOS 27 build host.

## Local workflow

Check the host and the known local vanilla image:

```shell
./scripts/image doctor
./scripts/image test sequoia-vanilla vanilla
```

Import the existing local macOS 15.6.1 image into the versioned image set, then build a base image from it:

```shell
./scripts/image import vanilla sequoia-vanilla
./scripts/image build base
```

The result is `macos-sequoia-15.6.1-base`. A failed provisioning stage leaves the VM in place so it can be inspected and resumed:

```shell
./scripts/image provision base macos-sequoia-15.6.1-base
```

Build the vanilla image from its pinned Apple IPSW:

```shell
./scripts/image build vanilla
```

The build waits 30 seconds after Tart reports installation complete, 90 seconds before the initial and post-Setup phases, and 45 seconds before resuming Setup Assistant. All waits are configurable:

```shell
CREATE_GRACE_TIME=60s SETUP_ASSISTANT_INITIAL_WAIT=120s SETUP_ASSISTANT_RESUME_WAIT=60s SETUP_ASSISTANT_FINAL_WAIT=120s SETUP_ASSISTANT_GATEKEEPER_WAIT=120s ./scripts/image build vanilla
```

Use a shorter wait only after validating it on the build host.

Tahoe has an additional user setup phase after the system terms and first login.
Its initial wait defaults to 90 seconds and can be set with
`SETUP_ASSISTANT_USER_WAIT`. The Setup Assistant sequences use a fixed display
and have a 30-minute deadline per phase.

An optional target name preserves an existing image while testing a fresh build:

```shell
./scripts/image build vanilla 90s macos-sequoia-15.6.1-test
```

Place Xcode at `~/XcodesCache/Xcode_<version>.xip`, then run:

```shell
./scripts/image build xcode 16.4
```

Select another image definition with `IMAGE_CONFIG`:

```shell
IMAGE_CONFIG=config/tahoe-26.6.2.env ./scripts/image doctor
```

## Registry workflow

Set `REGISTRY` to an OCI namespace such as `ghcr.io/example` and provide Tart registry credentials through `TART_REGISTRY_USERNAME` and `TART_REGISTRY_PASSWORD`.

Registry operations fail before invoking Tart when these credentials are missing.
If `TART_REGISTRY_HOSTNAME` is set, it must match the registry host. This prevents
fallback to host credential stores. Automatic Tart cache pruning is disabled.

```shell
REGISTRY=ghcr.io/example ./scripts/image pull base 15.6.1
REGISTRY=ghcr.io/example ./scripts/image push base 15.6.1
```

Images use immutable macOS version tags. Mutable tags are added only by the release workflow.

## Image layers

- `vanilla` installs macOS, creates the CI account, enables remote access, and installs Command Line Tools.
- `base` disables SIP, configures CI defaults, and installs common build and runner tooling.
- `xcode` installs a cached Xcode archive, Apple platforms, Android tooling, Flutter, and mobile development tools.

Setup Assistant flows are version-specific. All later provisioning runs over SSH. See [Architecture](docs/architecture.md) for the design and upgrade policy.
