# Releases

The `Build and publish macOS image` workflow is started manually from `main`.
It supports `vanilla`, `base`, and `xcode` for each configuration. Start with a
macOS 15 vanilla build when accepting a new runner or publication change.

## Names and tags

Package names and tags follow
[Cirrus macOS images](https://github.com/cirruslabs/macos-image-templates).

| Image | GHCR reference |
| --- | --- |
| Sequoia vanilla | `ghcr.io/minimillionaire/macos-sequoia-vanilla:15.8` |
| Tahoe vanilla | `ghcr.io/minimillionaire/macos-tahoe-vanilla:26.6.2` |
| Golden Gate vanilla | `ghcr.io/minimillionaire/macos-golden-gate-vanilla:27.0` |
| Tahoe base | `ghcr.io/minimillionaire/macos-tahoe-base:26.6.2` |
| Golden Gate base | `ghcr.io/minimillionaire/macos-golden-gate-base:27.0` |
| Sequoia with Xcode 26.3 | `ghcr.io/minimillionaire/macos-sequoia-xcode:15.6.1-xcode26.3` |
| Tahoe with Xcode 26.6 | `ghcr.io/minimillionaire/macos-tahoe-xcode:26.6.2-xcode26.6` |
| Golden Gate with Xcode 27 | `ghcr.io/minimillionaire/macos-golden-gate-xcode:27.0-xcode27` |

Vanilla and base use the macOS version as their primary tag. Set `update_latest`
only after confirming the release is current within its macOS major version;
the alias is promoted after the downloaded image passes its cold boot.

Each macOS family has one Xcode package. The primary tag includes both versions,
such as `26.7-xcode26.6` or `26.7-xcode27`. These identify separate combinations
in the macOS and Xcode matrix.

`xcode_version` is the installed compiler version. `xcode_tag` defaults to that
version and supplies the Xcode part of the combined tag. A prerelease can use
`xcode_version=27.0` and `xcode_tag=27-beta-6`. Their numeric versions must agree.

After acceptance, a stable publication also updates the Xcode version alias,
such as `26.6` or `27`, unless that alias already names a newer macOS version.
The existing alias's metadata must match the macOS family and Xcode version.
Older combinations remain available by their combined tag or digest. This is
independent of the optional `update_latest` choice, which updates the package's
`latest` alias and only accepts stable macOS and Xcode versions.

Tags can change after a rebuild. There is no project-version suffix or CI attempt
suffix. The manifest digest identifies exact image bytes; the OCI metadata and
publication records retain the macOS version/build, compiler version, source
commit, input hashes, and build run. Consumers needing a fixed image use
`ghcr.io/minimillionaire/macos-tahoe-xcode@sha256:...`.

Vanilla and base publications do not create Git tags or GitHub Releases. Xcode
publications use a GitHub Release named for the combined tag, such as
`26.7-xcode26.6`. Its assets distinguish the macOS profile and publication run,
so a rebuild can be recorded without replacing earlier evidence. The hosted Release job creates
an absent Git tag at the verified source revision and never moves an existing
tag. Individual image records identify their own build revisions and macOS
prerelease status. Prerelease macOS or Xcode versions produce prerelease Releases.
Migrating an Xcode-only Release changes its Release tag to the combined tag;
the original Git tag and assets remain unchanged.

## Runner

Use a dedicated Apple silicon Mac with the versions in `config/toolchain.env`,
the installed Tart Packer plugin, jq, and the PEM bundle configured by
`IMAGE_CACERT`. The host macOS version must meet the selected profile's minimum.
Xcode builds require the exact XIP archive in `~/XcodesCache`. Download it from
[Apple Developer Downloads](https://developer.apple.com/download/all/?q=Xcode)
and name it `Xcode_<xcode_version>.xip`. The filename uses the compiler version,
not the publication tag: `xcode_version=27.0` and `xcode_tag=27` require
`Xcode_27.0.xip`. Use `XCODE_CACHE` to select another cache directory.
Apple Silicon archives can keep Apple's filename,
`Xcode_<xcode_version>_Apple_silicon.xip`. When both filenames exist, builds use
the Apple Silicon archive.

The archive is reused across macOS builds. CI checks that it is a readable,
nonempty regular file before downloading the vanilla image, and records its SHA-256
in the build inputs. This hash records the supplied file; it is not an
independent Apple checksum. Packer copies the archive into the VM, where
`xcodes` installs it. Apple login credentials are not needed by the image build.
Host-side Apple login and automatic Xcode downloads are not configured.
Xcode builds install the arm64 simulator runtimes with
`xcodebuild -downloadAllPlatforms -exportPath`, import each package with
`xcodebuild -importPlatform`, then remove the downloaded packages.

The hosted authorization job permits only the configured `TRUSTED_ACTOR`
(default `cocoa-xu`), including the person requesting a rerun. It validates the
repository, main revision, configuration, and variant before scheduling the Mac.
There are no pull request triggers.

Source checkout uses `actions/checkout@v7` on Ubuntu. The hosted job packages the
source and locked Swift dependency into Git bundles and supplies the Go vendor
sources with a recorded SHA-256. The Mac receives those artifacts, clones them
locally, and builds with a local SwiftPM mirror and vendored Go dependencies.
Network Git transports, Go module downloads, and Go toolchain downloads are
disabled for that job.

The Mac job has package-write permission. Registry credentials are confined to
registry checks, digest uploads, and tag updates. ORAS receives them through
stdin and a private temporary auth file, with an explicit PEM CA bundle. Export
and anonymous verification do not receive registry credentials. Only the hosted
Release job gets `contents: write`.

Repository workflow checks do not restrict other repositories that can schedule
the same runner. Limit the runner's repository access separately and keep control
of changes to workflows and runner configuration.

## Build and publish

Choose the profile, variant, and operation in Actions. For Xcode, provide its
exact compiler version and, optionally, a separate tag. Base builds consume the
corresponding published vanilla image. Xcode builds use that same vanilla and
install the base tools before Xcode.
Their source tags are resolved to digests and checked against the selected
macOS version/build before use.

The runner caches parent OCI images under
`~/.cache/macos-image/parents/minimillionaire-macos-image`. Each run resolves the
parent tag again, then checks every cached blob against that digest before use.
The task gets a private APFS clone of the cached layout. A cache miss downloads
the pinned digest; a corrupt entry is discarded and downloaded again. Successful
vanilla publications retain their verified layout for base and Xcode builds.

The cache keeps at most two entries and 64 GiB, removing the least recently used
entries first. Other entries can be removed to meet a build's disk requirement.
An already cached parent counts toward the workspace allowance because its
downloaded bytes are already on disk. Cache maintenance uses the workflow's
serialized image jobs and only removes directories with matching ownership
markers. Interrupted cache writes are removed by cleanup or the next run.

- `build` constructs the image, verifies a separate cold boot, and saves the
  verified bundle for possible publication.
- `publish` builds and verifies the image, uploads it by digest, and verifies the
  downloaded image before updating its tag.
- `upload-only` takes a verified source run, exports and uploads its image by
  digest, and confirms the remote digest. It does not download anonymously,
  update tags, or create a release. It uploads without changing package visibility.
- `recover-upload` takes a previous run ID and attempt, such as `123456789-1`.
  It validates that run's evidence and restores its exact prepared export, or
  its verified VM bundle if the source run stopped before preparation.
- `recover-release` creates or completes an Xcode GitHub Release from verified
  publication results. It checks successful digest verification and tag promotion,
  the saved publication record, and the current anonymous registry references.
  It does not schedule the Mac runner or require local cache cleanup to succeed.

After uploading by digest, the pipeline downloads every blob anonymously,
verifies its hash and image identity, imports it into an isolated Tart home,
and checks a cold boot. Only then does a credentialed step update the requested
version or latest tag. A final anonymous check confirms that each tag resolves
to the verified digest. Earlier tags remain untouched if digest verification fails.

A new GHCR package must be public for anonymous acceptance. Configure its
visibility before retrying verification. Publication evidence stays in Actions
artifacts, with additional release assets for Xcode images.

After `upload-only`, the saved result remains at `prepared`. Use that upload run
as `source_run` for `recover-upload` when ready to complete anonymous acceptance
and update tags. Prepared recovery requires the retained OCI layout and original
bundle metadata; it preserves the original export and digest without restoring
a raw VM. Built-only recovery still requires the verified local VM bundle.

After preparation succeeds, a separate step verifies the retained export and
atomically records its digest, layout metadata hash, original bundle metadata
hash, and import-space bound. It then removes the run's private Tart storage and
saved raw VM. An interruption during removal preserves layout-based recovery.
The original `bundle.json` remains unchanged. Recovery must reference a run with
successful preparation evidence once its raw storage has been retired.

After the anonymous download passes verification, the saved recovery layout
shares its blobs with that download through APFS clones. Each replacement is
atomic and checked against its digest. The original task export is then removed
before import. An interrupted replacement leaves the exact export recoverable.

Upload-only runs reserve the saved bundle's full logical size, five percent for
export overhead, and 2 GiB of remaining workspace for tools and temporary files.
Restoring and retaining the bundle use APFS clones. If the source run already has a prepared
export, recovery requires the same APFS volume and only the 2 GiB workspace
allowance before retiring raw storage. Publication then checks space before
downloading and importing, reserving 20 GiB beyond each stage's requirement
and pruning unused parent caches when necessary. The import check uses the
saved bundle's full logical size. Fresh builds still
require 100 GiB free, or 250 GiB for Xcode images, to allow for builds and
downloaded image checks, less the space already occupied by the verified parent
cache selected for that build.

## Recovery and cleanup

For a locally modified, accepted image, `Publish prepared macOS image` uploads an
existing OCI export without rebuilding it. Put the export at
`~/.cache/macos-image/prepared/<manifest-sha256>/layout` on the runner, where
`<manifest-sha256>` omits the `sha256:` prefix. Dispatch `upload` with the complete
digest and image configuration. The workflow verifies the export and uploads by
digest without changing tags.

Download that digest anonymously, verify all blobs, import it, and verify a cold
boot. Save `verification.json` beside the layout with `manifest_digest`, the
primary tag in `reference`, `anonymous_download: "passed"`, `cold_boot: "passed"`,
and the guest's `boot_session`. Dispatch `promote` with the same inputs and that
file's SHA-256. This maintainer-supplied record is saved with the workflow's
artifacts. Promotion updates the primary tag and eligible Xcode alias, then
confirms their public digests. To replace an existing `latest` alias, also record
its current digest as `previous_digest` and select `update_latest`. Promotion
refuses to move `latest` if it has changed to a different image in the meantime.
This workflow does not create a Release.
Keep the export until publication succeeds; remove it manually afterward.

Recovery verifies the original authorized run, source revision, configuration
hashes, and saved VM hashes. It preserves the first successful OCI export:
Tart's manifest contains an upload timestamp, so re-exporting the same VM would
change its digest. Recovery uses the saved digest independently of mutable tags.
It can resume after an upload, boot verification, or partial tag update.

When recovering a Release from an older build, its workflow files may differ
from `main`. GitHub does not let `GITHUB_TOKEN` create that historical tag.
Create and push the Xcode tag at the exact `revision` in the accepted result
using a maintainer account, then run `recover-release`. The workflow uses the
existing tag without moving it. See GitHub's
[release API permissions](https://docs.github.com/en/rest/releases/releases#create-a-release).

Each run has its own Tart home and ownership marker. Cleanup stops its VMs,
checks that their disks are closed, and removes its temporary files. Failed
verification clones are deleted after their logs are saved. Unrelated VMs are
never touched, and automatic Tart pruning remains disabled.

Verified recovery bundles live under `~/.cache/macos-image/verified`. Failed
publication retains its prepared export and original bundle metadata, or its
verified raw bundle if preparation has not completed. Successful
anonymous verification of the promoted tags is followed by a separate cleanup
step with 20 minutes to verify and remove that cache. Small logs and
result files are uploaded as Actions artifacts even when a stage fails.

See [Validation](validation.md) for completed checks and full workflow acceptance.
