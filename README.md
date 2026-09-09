# macOS images for Tart

This repository builds reproducible macOS virtual machine images for Tart. It supports a local-first workflow and OCI publication.

The current image definitions are:

| Configuration | Restore image | Local build host |
| --- | --- | --- |
| `sequoia-15.6.1` | macOS 15.6.1 (24G90) | macOS 15 or newer |
| `tahoe-26.6.2` | macOS 26.6.2 (25G83) | macOS 26 or newer |

## Requirements

- Apple silicon
- Tart 2.36 or newer
- Packer 1.14 or newer
- A local Xcode XIP archive for Xcode images

Packer installs the pinned Tart plugin with `packer init`.

## Local workflow

Check the host and the known local vanilla image:

```shell
./scripts/image doctor
./scripts/image test sequoia-vanilla-pristine vanilla
```

Build a base image from the existing local macOS 15.6.1 image:

```shell
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

```shell
REGISTRY=ghcr.io/example ./scripts/image pull base 15.6.1
REGISTRY=ghcr.io/example ./scripts/image push base 15.6.1
```

Images use immutable macOS version tags. Mutable tags are added only by the release workflow.

## Image layers

- `vanilla` installs macOS, creates the CI account, enables remote access, and installs Command Line Tools.
- `base` disables SIP, configures CI defaults, and installs common build and runner tooling.
- `xcode` installs a cached Xcode archive, Apple platforms, Android tooling, Flutter, and mobile development tools.

The macOS 15 and 26 Setup Assistant flows are version-specific. All later provisioning runs over SSH. See [Architecture](docs/architecture.md) for the design and upgrade policy.

