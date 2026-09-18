# Validation

## Sequoia upgrade builds

Sequoia 15.7.7 (24G720) passed the full build and publication workflow in
[35326226572](https://github.com/MiniMillionaire/macos-image/actions/runs/35326226572)
at revision `e5b0f8d`. It upgraded directly from the pinned 15.6.1 vanilla
image using Apple's full installer, without UI input. The disk grew to 100 GB
with Recovery preserved. Installer staging was removed after the upgraded
system booted.

The build passed two cold-boot checks. CI then uploaded the 20.94 GiB OCI image,
downloaded every blob anonymously, verified its hashes, and cold-booted the
imported image. The downloaded boot session was
`B1E215B6-490A-457B-9D8F-7DD7277DD3C3`. Checks covered the exact OS/build,
admin account, locale, keyboard, automatic login, CLT, and disabled FileVault.

The published image is `ghcr.io/minimillionaire/macos-sequoia-vanilla:15.7.7`:

```text
sha256:46ed1ff2f17460c427cef8e19d189b5b1ea6f180f3735cfbc092a8838123208e
```

Anonymous tag checks passed. `latest` remains at 15.6.1. CI removed its task VMs
and recovery bundle after publication and retained the verified parent cache.

## IPSW builds

The macOS 15.6.1, 26.6.2, and 27.0 vanilla images passed fresh builds from
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

## Repository workflow

These vanilla builds passed this repository's workflow:

| macOS | Apple build | Revision | Clean CI build |
| --- | --- | --- | --- |
| 15.6.1 | 24G90 | `e4c3c95` | [34864129124](https://github.com/MiniMillionaire/macos-image/actions/runs/34864129124) |
| 26.6.2 | 25G83 | `cd97509` | [34870929943](https://github.com/MiniMillionaire/macos-image/actions/runs/34870929943) |
| 27.0 RC | 26A428 | `cd97509` | [34879583705](https://github.com/MiniMillionaire/macos-image/actions/runs/34879583705) |

Each restored the pinned IPSW and verified a cold boot of a separate clone.
The macOS 27 build originally used the RC designation. Its IPSW is identical to
the September 14 release, as confirmed by a [full-file check](macos-27.md#restore-image)
on September 17. The original build records and image digest are unchanged.

macOS 15 completed four Setup Assistant sequences and installed Command Line
Tools 16.4. macOS 26 completed five sequences and installed Command Line Tools
26.6. macOS 27 used native account provisioning, a fixed Gatekeeper sequence,
and Command Line Tools 27.0. The runner was launched over SSH as described in
[Host setup](host-setup.md).

Verified bundles were saved for publication. Their metadata matched the downloaded
Actions artifacts, and each task's temporary files were removed.

All three images were uploaded by digest:

| macOS | Upload run | OCI blob size |
| --- | --- | --- |
| 15.6.1 | [34868521410](https://github.com/MiniMillionaire/macos-image/actions/runs/34868521410) | 19.58 GiB |
| 26.6.2 | [34882256051](https://github.com/MiniMillionaire/macos-image/actions/runs/34882256051) | 23.12 GiB |
| 27.0 RC | [34885745399](https://github.com/MiniMillionaire/macos-image/actions/runs/34885745399) | 28.88 GiB |

ORAS transferred the manifests and blobs and confirmed the remote digests.
All three packages remained private. The macOS 15 and 26 workflows stopped at
anonymous verification. The macOS 27 upload-only workflow passed and skipped
anonymous verification and tag promotion. No tags or Releases were created.
The original verified bundles and exports were retained for recovery, and the
temporary task directories were removed.

On September 16, 2026, all three packages were made public. Anonymous manifest
and configuration downloads passed their SHA-256 checks and matched the original
upload records. A HEAD request for a disk blob in each image returned 200 with
the expected size. The local VM and OCI caches were removed during disk cleanup;
metadata and CI records were retained.

Sequoia and Tahoe completed publication on September 16:

| macOS | Publication run | Tag |
| --- | --- | --- |
| 15.6.1 | [35071207716](https://github.com/MiniMillionaire/macos-image/actions/runs/35071207716) | `macos-sequoia-vanilla:latest` |
| 26.6.2 | [35071876839](https://github.com/MiniMillionaire/macos-image/actions/runs/35071876839) | `macos-tahoe-vanilla:latest` |

Both runs downloaded the full image anonymously, checked its OCI hashes,
imported it, and verified a separate cold boot before publishing the tag under
`ghcr.io/minimillionaire`. Anonymous tag checks passed. The original digests
were preserved:

- Sequoia: `sha256:37db3b09d4877a2522adc80aa944f91cc3f9f659cde65af8c4d405e43e4e15f3`
- Tahoe: `sha256:86777a3e30fcbba7d8fe6aeb43adbab33e9cecbc249c3ccdf26b17511ff0f8ba`

The saved bundles and temporary task directories were removed after publication.

Golden Gate completed the same acceptance process on September 17 in
[35218017615](https://github.com/MiniMillionaire/macos-image/actions/runs/35218017615),
preserving its original export and digest:

- Reference: `ghcr.io/minimillionaire/macos-golden-gate-vanilla:latest`
- Digest: `sha256:a2883aa8087c07b452a56a6c441a69e7064384bb662004c610e293c900aa11ce`
- Downloaded image boot: `87671189-3FF1-427E-BAD5-88B81803CC8F`

## Base images

All three base variants completed CI builds and publication:

| macOS | Revision | CI run | OCI blob size |
| --- | --- | --- | --- |
| 15.6.1 | `2600459` | [35073451718](https://github.com/MiniMillionaire/macos-image/actions/runs/35073451718) | 21.52 GiB |
| 26.6.2 | `abc2a00` | [35077863586](https://github.com/MiniMillionaire/macos-image/actions/runs/35077863586) | 25.91 GiB |
| 27.0 | `7248c30` | [35225773768](https://github.com/MiniMillionaire/macos-image/actions/runs/35225773768) | 31.17 GiB |

Each build cloned its published vanilla image by digest, disabled SIP in Recovery,
and installed the base tools. Provisioning and separate cold-boot checks passed.
The workflows then uploaded, downloaded anonymously in full, imported, and
verified another cold boot before publishing `latest`:

- `ghcr.io/minimillionaire/macos-sequoia-base:latest`:
  `sha256:5c21aab8e4e7445224074ad0a00b775a27735b29f06ff6a746d6f04bb2064193`
- `ghcr.io/minimillionaire/macos-tahoe-base:latest`:
  `sha256:953eb700bcddb98ccdedbf4ef39cd0a5e9666ec1ff488acbb0ed8f0dc64ff601`
- `ghcr.io/minimillionaire/macos-golden-gate-base:latest`:
  `sha256:f7e98e34e06f800333a01443f06e06c14500e9f4c437ccf3b9b385d1cd162468`

Anonymous tag checks passed. All OS versions and Apple builds remained unchanged.
The temporary VMs, downloaded images, and saved recovery bundles were removed
after publication.

The published vanilla and base `latest` tags also have macOS version aliases:
`15.6.1` for Sequoia, `26.6.2` for Tahoe, and `27.0` for Golden Gate. Each alias
resolves to the same manifest digest as its corresponding `latest` tag. The
[tagging run](https://github.com/MiniMillionaire/macos-image/actions/runs/35304562468)
completed successfully, and all six pairs were checked anonymously.

Golden Gate uses the current user's `tccd` process to locate its relocated
[privacy database](macos-27.md#automation-permissions). Its downloaded-image
cold boot passed with session `B8A09A60-B63F-42B5-B2EC-12D1E245A6A7`.

## Xcode images

Sequoia 15.6.1 (24G90) with Xcode 26.3 passed its build and independent cold boot
in [35096059846](https://github.com/MiniMillionaire/macos-image/actions/runs/35096059846),
at revision `fb81cc1`. Publication continued from the same verified bundle and
OCI export in [35100517384](https://github.com/MiniMillionaire/macos-image/actions/runs/35100517384).
The complete 59.86 GiB image was downloaded anonymously, checked, imported,
and cold-boot tested before tag `26.3` was promoted.

- Reference: `ghcr.io/minimillionaire/macos-sequoia-xcode:26.3`
- Digest: `sha256:c7bdd6d7fdd7722a0b9eb8978558df9bd08678eff58d9b0234ae9701c32bf6c1`
- Downloaded image boot: `05BB2D35-D241-4D88-97B9-BA0904C2D57A`
- Release: [26.3](https://github.com/MiniMillionaire/macos-image/releases/tag/26.3)

Checks covered Xcode, its four arm64 simulator runtimes, Tuist, Flutter,
Android SDK 36, CocoaPods, and fastlane. Flutter's Xcode and Android checks
passed. Chrome is not installed. The macOS version/build, account, language,
and keyboard settings remained unchanged.

The publication job timed out while hashing its local recovery bundle after
successful tag confirmation. Cache removal now runs separately. Release recovery
[35112072265](https://github.com/MiniMillionaire/macos-image/actions/runs/35112072265)
passed, including anonymous registry checks and verification of uploaded release
assets. The saved recovery bundle and temporary VMs were removed. No `latest`
alias was updated.

Tahoe 26.6.2 (25G83) with Xcode 26.6 completed its build and publication acceptance
in [35112264080](https://github.com/MiniMillionaire/macos-image/actions/runs/35112264080),
at revision `4c45230`. The workflow used its published base image, installed the
Apple Silicon XIP and all four arm64 simulator runtimes, and verified separate
cold boots before and after publication.

- Reference: `ghcr.io/minimillionaire/macos-tahoe-xcode:26.6`
- Digest: `sha256:d1257eec6bb3c52e37bc77dbf974e38c4862e7dbd8cb9bc30c5417079b38bd25`
- OCI blob size: 63.27 GiB
- Downloaded image boot: `254BC390-2001-4F66-85CC-7B14E6F9159A`
- Release: [26.6](https://github.com/MiniMillionaire/macos-image/releases/tag/26.6)

The macOS version/build and locale settings remained unchanged. Xcode, Flutter,
Android, and the installed development tools passed verification. The downloaded
runtimes were iOS 26.5 (23F77), watchOS 26.5 (23T570), tvOS 26.5 (23L470),
and visionOS 26.5 (23O470). The `latest` alias was not updated.
The same CI run completed cache cleanup and the hosted Release job, including
verification of uploaded assets. Its temporary VMs and recovery bundle were removed.

Golden Gate 27.0 (26A428) with Xcode 27.0 passed its build and independent cold
boot in [35236566556](https://github.com/MiniMillionaire/macos-image/actions/runs/35236566556),
at revision `1576362`. Publication continued from that verified build in
[35258270949](https://github.com/MiniMillionaire/macos-image/actions/runs/35258270949).
The complete 63.09 GiB image was downloaded anonymously, checked, imported,
and cold-boot tested before tag `27` was promoted.

- Reference: `ghcr.io/minimillionaire/macos-golden-gate-xcode:27`
- Digest: `sha256:4bdf7fd662476fcabea8168377916f345229dd38c3cae50b1a6436ea113153b3`
- Downloaded image boot: `1890CF34-D836-4178-B36F-C55D81E7F492`
- Release: [27](https://github.com/MiniMillionaire/macos-image/releases/tag/27)

The Apple Silicon Xcode archive, all four arm64 simulator runtimes, Flutter,
Android SDK 36, and the development tools passed verification. The macOS
version/build, account, language, and keyboard settings remained unchanged.
Chrome is not installed. No `latest` Xcode alias was updated. The temporary VMs
and saved recovery bundle were removed after publication.

## Parent cache

Three separate Sequoia Xcode CI builds reused the same verified base image
without downloading its 21.52 GiB OCI layout again. Each run resolved the parent
tag and checked the cached bytes before creating a private APFS clone. Disk
pressure during publication later removed the owned parent cache.

The anonymous publication download still transferred every blob. Once verified,
APFS clones let the saved recovery export share that downloaded storage before
import. In run `35100517384`, this recovered about 60 GiB; the lowest observed
free space during import and cold boot was about 41 GiB. Inline checks also
covered interrupted replacement, corrupt blobs, wrong digests, and symlinks,
while preserving the original export after a rejected replacement.

Tahoe passed the same publication path. The pre-import space check removed its
25.91 GiB parent cache after blob sharing completed. The lowest observed free
space was 19.91 GiB at the end of the anonymous download, and about 30 GiB
remained after cold-boot acceptance. Final cleanup restored about 259 GiB free.

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

A second physical download host and VirtualBuddy import are outside the
recorded results.

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
