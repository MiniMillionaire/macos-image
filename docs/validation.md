# Validation

The macOS 15.6.1, 26.6.2, and 27.0 RC vanilla recipes passed fresh builds from
pinned Apple IPSWs on an Apple M4 Pro Mac mini running macOS 27.0 (26A5425a).
The builds used revision `34f3fbe`, Tart 2.36.0, Packer 1.16.0, Go 1.25.0, and
Tart Packer plugin 1.21.0.

| macOS | Apple build | Clean CI build |
| --- | --- | --- |
| 15.6.1 | 24G90 | [34752571489](https://github.com/cocoa-xu/nerves_system_macos/actions/runs/34752571489) |
| 26.6.2 | 25G83 | [34755074300](https://github.com/cocoa-xu/nerves_system_macos/actions/runs/34755074300) |
| 27.0 RC | 26A428 | [34758635823](https://github.com/cocoa-xu/nerves_system_macos/actions/runs/34758635823) |

These runs were hosted by `nerves_system_macos` and used this repository as their
builder. They completed fixed Setup Assistant sequences and SSH provisioning
without screenshots, OCR, or manual repairs. Checks covered the exact OS/build,
arm64, the admin account/full name/password, standard English, `en_US`, `en-US`,
U.S./ABC keyboard, and a cold boot of a separate clone.

Each published image was downloaded anonymously in full, checked against its
OCI hashes, imported into Tart, and booted independently. The macOS 15 build
also demonstrated recovery after a publication failure while retaining the
original build revision and image identity.

## Publication backport

The new local adapter passed a 16 MiB disk round trip through Tart export, ORAS
1.3.0 layout copy, and Tart import. Manifest/blob bytes, disk contents, and NVRAM
were preserved. Image identity labels were checked. A corrupted blob and an
existing VM destination were rejected.

The download helper passed HTTPS verification with an explicit PEM CA, rejected
an untrusted certificate and a checksum mismatch, and removed incomplete output.
A timed command that ignored SIGTERM was terminated along with its child process.
A fresh Swift build also passed using a local Git bundle for the locked
argument-parser dependency, an empty dependency cache, and network Git transports
disabled. The compiler was Swift 6.4. `make validate` passed the Packer syntax,
guest script, Go, existing Swift checks, actionlint, and ShellCheck.

The workflow's bootstrap, initialization, tool preflight, and cleanup steps also
passed locally against a clean source bundle. This included a fresh CLI build
with an empty dependency cache and the exact pinned tools. The registry helper
compiled for Linux amd64, where the Release job runs.

Controlled cache-write failures removed incomplete output while preserving the
source. An early recovery failure preserved the original verified bundle, and a
symlinked cache ancestor was rejected. The temporary disk bundles, registry data,
TLS material, and build trees were removed.

These checks do not constitute a fresh build or authenticated GHCR upload through
this repository's new workflow. The ORAS upload path still needs that acceptance
run. Base and Xcode variants, a second physical download host, and VirtualBuddy
import are outside the recorded results.

## Cirrus tag conventions

ORAS 1.3.0 passed a local HTTPS registry check using an explicit PEM CA. Uploading
by digest left an existing `latest` tag untouched. A full anonymous digest
download passed, and promotion then updated the tag while preserving the older
manifest. Xcode `16.4` and `latest` tags shared one package and digest. A prerelease
latest update and a mismatched digest were rejected. The registry and temporary
files were removed afterward.

`make validate` passed after the tag changes. The workflow bootstrap, tool
preflight, and cleanup also passed from a clean source bundle at `1b21a63`.
Swift built with a fresh dependency cache and a local mirror. The Go VNC
controller compiled from the supplied vendor archive with an empty dependency
module cache and network downloads disabled. The dependency lockfile and source
checkout stayed unchanged; no VM was created, and the temporary checkout was
removed. Prepared and verified publication records also passed recovery checks.

This verifies the transfer and tag-update behavior without claiming a full
macOS build or authenticated GHCR publication through the updated workflow.
