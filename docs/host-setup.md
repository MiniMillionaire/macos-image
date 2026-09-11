# Build host setup

The Apple silicon host was checked on September 11, 2026. It runs macOS 27.0
(26A5425a), has 24 GiB of memory, and had 274 GiB of free disk space before the
first Tahoe build. Xcode command line tools and Homebrew were already installed.
No Tart VMs existed at the start of the session.

The following ARM64 toolchain was installed from release archives. Each archive
was checked against the publisher's SHA-256 value before extraction.

| Tool | Version | Archive SHA-256 |
| --- | --- | --- |
| Tart | 2.36.0 | `c72a8ab8d78a6498a1e42688b1a1ec6c512ce46ca35a3a3be130c3de1440c7e8` |
| Packer | 1.16.0 | `6530042cf8f8a1f96b6607cb22b5be298be53b400cd4a2c81ab8b946964fccda` |
| Go | 1.25.0 | `544932844156d8172f7a28f77f2ac9c15a23046698b6243f633b0a0b00c0749c` |

Release metadata: [Tart](https://github.com/cirruslabs/tart/releases/tag/2.36.0),
[Packer checksums](https://releases.hashicorp.com/packer/1.16.0/packer_1.16.0_SHA256SUMS),
and [Go archives](https://go.dev/dl/#go1.25.0).

Versioned installations are under `~/.local/share/macos-image/toolchains`.
Symlinks for `tart`, `packer`, `go`, and `gofmt` are in `/opt/homebrew/bin`.
`packer init` installed Tart plugin 1.21.0 under
`~/.config/packer/plugins/github.com/cirruslabs/tart`.

Check the installation with:

```shell
tart --version
packer --version
go version
IMAGE_CONFIG=config/tahoe-26.6.2.env ./scripts/image doctor
./scripts/image validate
packer fmt -check -recursive .
go test ./...
git diff --check
```

Local IPSW installation and local VM operations do not require registry
credentials. Never use the host Keychain for this project. Registry operations
require explicit `TART_REGISTRY_USERNAME` and `TART_REGISTRY_PASSWORD`; Tart's
fallback credential providers can otherwise access the host Keychain.
