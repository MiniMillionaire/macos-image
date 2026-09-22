# macOS images for Tart

This repository builds macOS virtual machine images for Tart. It supports local builds and OCI publication.

The current image definitions are:

| Configuration | macOS source | Local build host |
| --- | --- | --- |
| `sequoia-15.6.1` | macOS 15.6.1 (24G90) | macOS 15 or newer |
| `sequoia-15.7.7` | Upgrade 15.6.1 vanilla to 15.7.7 (24G720) | macOS 15 or newer |
| `sequoia-15.7.8` | Upgrade 15.6.1 vanilla to 15.7.8 (24G824) | macOS 15 or newer |
| `sequoia-15.7.9` | Upgrade 15.6.1 vanilla to 15.7.9 (24G830) | macOS 15 or newer |
| `sequoia-15.8` | Upgrade 15.6.1 vanilla to 15.8 (24H23) | macOS 15 or newer |
| `tahoe-26.6.2` | macOS 26.6.2 (25G83) | macOS 26 or newer |
| `golden-gate-27.0` | macOS 27.0 (26A428) | macOS 27 or newer |

The three IPSW-based vanilla images and the Sequoia upgrade images through 15.8
passed CI builds, full anonymous downloads, and independent cold boots. Vanilla
`latest` tags point to Sequoia 15.8, Tahoe 26.6.2, and Golden Gate 27.0 under
`ghcr.io/minimillionaire`. Earlier versions remain available by numbered tag.

Base and Xcode images passed the same acceptance process for macOS 15.6.1,
26.6.2, and 27.0. Their Xcode versions are 26.3, 26.6, and 27 respectively.
See the [validation record](docs/validation.md) for published combinations,
digests, and CI runs.

## Requirements

- Apple silicon
- A host with `diskutil image resize` (verified on macOS 27)
- Tart 2.36 or newer
- Packer 1.14 or newer
- Go 1.25 or newer
- Swift 6 or newer
- ORAS 1.3.0 and jq for registry operations
- A PEM CA bundle for downloads
- A local Xcode XIP archive for Xcode images

`make validate` also requires actionlint and ShellCheck.

Install the pinned Tart Packer plugin before building. The build checks for the
local plugin and does not download it. Packer update checks and telemetry are
disabled by the tracked configuration. Swift Package Manager uses the locked CLI
dependency with Keychain access disabled. Builds allow only local Git transports
and disable Go network dependency fetches. CI provides source bundles, Go vendor
sources, and a local Swift dependency mirror.

The verified toolchain is Tart 2.36.0, Packer 1.16.0, Go 1.25.0, Swift 6.4,
and the Tart Packer plugin 1.21.0. See [Host setup](docs/host-setup.md) for the
installation record on the macOS 27 build host.

## Command-line interface

For a first local build, configure the [local dependency mirror](docs/host-setup.md#swift-dependency).

Build the release CLI:

```shell
make cli
```

The executable is `.build/release/macos-image`. It locates the repository from
the current directory or its ancestors. Use `--repository` when running it from
elsewhere.

```shell
.build/release/macos-image --help
.build/release/macos-image doctor
.build/release/macos-image doctor --config config/tahoe-26.6.2.env
```

The Swift package exposes `MacOSImageCore` separately from the executable so a
future SwiftUI application can use the same operation model and process runner.
The CLI delegates execution to `scripts/image`. A compiled Go helper handles
verified downloads, command deadlines, and the local Tart/OCI format adapter.
That script remains available as a compatibility entry point while orchestration
moves into the shared Swift core.

## Local workflow

Check the host and the known local vanilla image:

```shell
.build/release/macos-image doctor
.build/release/macos-image test sequoia-vanilla --profile vanilla
```

Import the existing local macOS 15.6.1 image into the versioned image set, then build a base image from it:

```shell
.build/release/macos-image import vanilla --source sequoia-vanilla
.build/release/macos-image build base
```

The result is `macos-sequoia-15.6.1-base`. A failed provisioning stage leaves the VM in place so it can be inspected and resumed:

```shell
.build/release/macos-image provision base macos-sequoia-15.6.1-base
```

Build the vanilla image from its pinned Apple IPSW. The download must match both
the recorded size and SHA-256 before Tart can restore it:

```shell
.build/release/macos-image build vanilla
```

The build waits 30 seconds after Tart reports installation complete, 90 seconds before the initial and post-Setup phases, and 45 seconds before resuming Setup Assistant. All waits are configurable:

```shell
CREATE_GRACE_TIME=60s SETUP_ASSISTANT_INITIAL_WAIT=120s SETUP_ASSISTANT_RESUME_WAIT=60s SETUP_ASSISTANT_FINAL_WAIT=120s SETUP_ASSISTANT_GATEKEEPER_WAIT=120s .build/release/macos-image build vanilla
```

Use a shorter wait only after validating it on the build host.

Versions without an IPSW upgrade directly from the nearest preceding official
IPSW's vanilla image within the same macOS major. Each target pins that source
by digest; patch releases are not chained together. A newer official IPSW starts
the next set of upgrade builds. See the [upgrade policy](docs/macos-updates.md#build-policy).

To build an upgrade image:

```shell
REGISTRY=ghcr.io/minimillionaire .build/release/macos-image build vanilla --config config/sequoia-15.7.7.env
```

The installer is cached by SHA-256 in `~/.cache/macos-image/installers` and
verified before each use. `INSTALLER_CACHE_DIR` overrides that directory.
Every build runs on a sparse 256 GB disk. When a build finishes, the disk is
shrunk to the smallest multiple of 10 GB that leaves at least 8 GiB free, and
Recovery is kept. See [Disk size](docs/disk-size.md#build-and-published-sizes).

Tahoe has an additional user setup phase after the system terms and first login.
Its initial wait defaults to 90 seconds and can be set with
`SETUP_ASSISTANT_USER_WAIT`. The Setup Assistant sequences use a fixed display
and have a 30-minute deadline per phase.

An optional target name preserves an existing image while testing a fresh build:

```shell
.build/release/macos-image build vanilla --initial-wait 90s --target macos-sequoia-15.6.1-test
```

Place Xcode at `~/XcodesCache/Xcode_<version>.xip`, then run:

```shell
.build/release/macos-image build xcode 26.3
```

Each Xcode build starts from the matching macOS vanilla image and installs the
base tools before Xcode. Existing base or Xcode images are not required.

Select another image definition with `IMAGE_CONFIG`:

```shell
.build/release/macos-image doctor --config config/tahoe-26.6.2.env
```

## Registry workflow

Set `REGISTRY` to an OCI namespace and `IMAGE_CACERT` to a PEM CA bundle.
Public downloads use an empty registry credential configuration:

```shell
export REGISTRY=ghcr.io/example
export IMAGE_CACERT=/opt/homebrew/etc/openssl@3/cert.pem
.build/release/macos-image pull vanilla
```

The downloaded image is checked and imported into the configured local VM name.
An existing VM with that name is never replaced. To prepare a larger working clone:

```shell
.build/release/macos-image resize macos-sequoia-15.6.1-vanilla \
  --target sequoia-work --disk-size 160
```

This preserves Recovery, checks usable capacity, and verifies a separate boot.
See [Disk size](docs/disk-size.md) for supported layouts and the difference from
`tart set --disk-size`.

To upload a stopped, verified VM,
provide `TART_REGISTRY_HOSTNAME`, `TART_REGISTRY_USERNAME`, and
`TART_REGISTRY_PASSWORD` explicitly, then run:

```shell
.build/release/macos-image push vanilla
```

Uploads require a clean checkout. Credentials are passed to ORAS through stdin
and a temporary private configuration file, which is removed on exit. Tart only
connects to the local format adapter; ORAS handles registry HTTPS with the
explicit CA bundle. Automatic Tart cache pruning is disabled.

Package names and tags follow
[Cirrus macOS images](https://github.com/cirruslabs/macos-image-templates):

```text
ghcr.io/minimillionaire/macos-sequoia-vanilla:latest
ghcr.io/minimillionaire/macos-sequoia-vanilla:15.6.1
ghcr.io/minimillionaire/macos-sequoia-vanilla:15.8
ghcr.io/minimillionaire/macos-tahoe-vanilla:latest
ghcr.io/minimillionaire/macos-tahoe-vanilla:26.6.2
ghcr.io/minimillionaire/macos-golden-gate-vanilla:latest
ghcr.io/minimillionaire/macos-golden-gate-vanilla:27.0
ghcr.io/minimillionaire/macos-tahoe-base:latest
ghcr.io/minimillionaire/macos-tahoe-base:26.6.2
ghcr.io/minimillionaire/macos-sequoia-xcode:15.6.1-xcode26.3
ghcr.io/minimillionaire/macos-sequoia-xcode:26.3
ghcr.io/minimillionaire/macos-tahoe-xcode:26.6.2-xcode26.6
ghcr.io/minimillionaire/macos-tahoe-xcode:26.6
ghcr.io/minimillionaire/macos-golden-gate-xcode:27.0-xcode27
ghcr.io/minimillionaire/macos-golden-gate-xcode:27
```

Vanilla and base use their macOS version as the primary tag. Their `latest` alias
is updated after a release is verified as current for that macOS major version.
Xcode versions share one package per macOS family. Their primary tag includes
both versions, such as `26.7-xcode26.6`. A numeric Xcode tag such as `26.6`
points to the newest published macOS version with that Xcode version in the
same family. Publishing an older combination preserves that alias.
Tags can change after a rebuild. Pin a manifest digest with `@sha256:...` when
consuming exact image bytes. OCI metadata records the macOS version, Apple
build, Xcode version, and source commit.

Sequoia publishes only `slim-xcode` because the current trimming process does
not materially reduce its vanilla or base images.

For Xcode registry operations, set `XCODE_VERSION` to the installed compiler
version. `XCODE_TAG` supplies the Xcode part of the combined tag and defaults to
that version; it can name a prerelease such as `27-beta-6` while `XCODE_VERSION`
is `27.0`. Numeric and combined pull tags supply the compiler version
automatically:

```shell
IMAGE_CONFIG=config/golden-gate-27.0.env .build/release/macos-image pull xcode --tag 27
```

CI uploads by digest and verifies the anonymous download and cold boot before
updating tags. Updating `latest` requires an explicit release choice. Xcode's
optional `latest` alias also requires a stable Xcode tag.

See [Releases](docs/releases.md) for CI authorization, verification, and recovery.

## Image layers

- `vanilla` installs macOS, creates the CI account, enables remote access, and installs Command Line Tools.
- `base` disables SIP, configures CI defaults, and installs common build and runner tooling.
- `xcode` installs a cached Xcode archive, Apple platforms, Android tooling, Flutter, and mobile development tools.

Setup Assistant flows are version-specific. All later provisioning runs over SSH. See [Architecture](docs/architecture.md) for the design and upgrade policy.
