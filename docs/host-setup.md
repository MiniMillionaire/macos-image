# Build host setup

The Apple silicon host was checked on September 11, 2026. It runs macOS 27.0
(26A5425a), has 24 GiB of memory, and had 274 GiB of free disk space before the
first Tahoe build. Xcode command line tools and Homebrew were already installed.
No Tart VMs existed at the start of the session.

The following ARM64 toolchain was installed. Release archives were checked
against the publisher's SHA-256 value before extraction.

| Tool | Version | Source or archive SHA-256 |
| --- | --- | --- |
| Tart | 2.36.0 with Recovery relocation | local signed build |
| Packer | 1.16.0 | `6530042cf8f8a1f96b6607cb22b5be298be53b400cd4a2c81ab8b946964fccda` |
| Go | 1.25.0 | `544932844156d8172f7a28f77f2ac9c15a23046698b6243f633b0a0b00c0749c` |

The current Xcode toolchain provides Swift 6.4 for building the compiled CLI.
This version passed validation on September 14, 2026.

Release metadata: [Tart fork](https://github.com/MiniMillionaire/tart),
[Packer checksums](https://releases.hashicorp.com/packer/1.16.0/packer_1.16.0_SHA256SUMS),
and [Go archives](https://go.dev/dl/#go1.25.0).

Versioned installations are under `~/.local/share/macos-image/toolchains`.
Symlinks for `tart`, `packer`, `go`, and `gofmt` are in `/opt/homebrew/bin` or
`~/.local/bin`.
`packer init` installed Tart plugin 1.21.0 under
`~/.config/packer/plugins/github.com/cirruslabs/tart`.

Check the installation with:

```shell
export PACKER_CONFIG="$PWD/config/packer.json"
tart --version
tart set --help | grep -- --relocate-recovery
packer --version
go version
xcrun swift --version
make cli
.build/release/macos-image doctor --config config/tahoe-26.6.2.env
.build/release/macos-image validate
packer fmt -check -recursive .
go test ./...
git diff --check
```

Local IPSW installation and local VM operations do not require registry
credentials. Never use the host Keychain for this project. Registry uploads
require explicit `TART_REGISTRY_HOSTNAME`, `TART_REGISTRY_USERNAME`, and
`TART_REGISTRY_PASSWORD`. ORAS uses a private temporary auth configuration and an
explicit PEM CA bundle. Public downloads use an empty auth configuration. Tart
only connects to the loopback adapter for registry operations.

`config/toolchain.env` records the verified tool versions. CI requires exact
matches. `config/packer.json` disables Checkpoint before every Packer invocation.
The Tart plugin must already be installed; builds do not use `packer init` to
fetch missing plugins. Downloaded IPSWs use an explicit PEM trust pool and must
match their configured size and SHA-256. Set `IMAGE_CACERT` to use another PEM CA
bundle; the default is `/opt/homebrew/etc/openssl@3/cert.pem`.

Start the runner from Apple Terminal or an SSH session. macOS allows local
network access for command-line tools launched there, including their children.
For other applications, access depends on the application macOS identifies as
responsible for the connection. See Apple's
[Local Network privacy guidance](https://developer.apple.com/documentation/technotes/tn3179-understanding-local-network-privacy).

On this host, Packer returned `EHOSTUNREACH` from a runner launched through iTerm
despite a valid route and ARP entry. The same Python TCP probe failed in an
application context and connected through localhost SSH. Restarting the runner
over SSH also let the unchanged Packer build connect. A successful connection
from `nc` alone did not establish that Packer could connect. Compare the same
program and guest address across launch contexts before changing the guest,
network settings, or Setup Assistant sequence.

## Swift dependency

The first local CLI build needs a local Git checkout or mirror of
`apple/swift-argument-parser` containing the revision in `Package.resolved`.
Point SwiftPM at that repository before running `make cli`:

```shell
SWIFT_ARGUMENT_PARSER_PATH=/absolute/path/to/swift-argument-parser
GIT_ALLOW_PROTOCOL=file xcrun swift package --disable-keychain config set-mirror \
  --original https://github.com/apple/swift-argument-parser \
  --mirror "file://$SWIFT_ARGUMENT_PARSER_PATH"
printf '.swiftpm/\n' >> .git/info/exclude
make cli
```

The mirror is local configuration and must not be committed. CI supplies its own
mirror from a Git bundle. `GIT_ALLOW_PROTOCOL=file` applies to build processes;
it does not change the user's Git configuration or restrict IPSW and OCI transfers.

Go builds also disable module and toolchain downloads. Local builds need the
`go-vnc` dependency from `go.sum` in their existing module cache. CI supplies a
verified vendor archive from its hosted job, so the Mac does not fetch Go source
or checksums over HTTPS.
