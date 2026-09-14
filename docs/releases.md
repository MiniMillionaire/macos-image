# Releases

The `Build and publish macOS image` workflow is started manually from `main`.
It supports `vanilla`, `base`, and `xcode` for each configuration. Start with a
macOS 15 vanilla build when accepting a new runner or publication change.

## Versions

`IMAGE_VERSION` in the selected configuration is independent of the macOS
version. The OCI tag is `<macOS version>-<Apple build>-v<image version>`, for
example `26.6.2-25G83-v0.1.0`. A rebuild uses a new image version such as `0.1.1`.

Variants use different packages. Git tags include the variant so their releases
can be created independently:

| Variant | GHCR package | Git tag example |
| --- | --- | --- |
| Vanilla | `macos-tahoe-vanilla` | `vanilla/26.6.2-25G83-v0.1.0` |
| Base | `macos-tahoe-base` | `base/26.6.2-25G83-v0.1.0` |
| Xcode 26.0 | `macos-tahoe-xcode-26.0` | `xcode-26.0/26.6.2-25G83-v0.1.0` |

Run IDs and attempt numbers belong only to CI records and recovery requests.
They are never appended to an image version. Existing tags cannot be overwritten.
macOS 27 RC releases are marked prerelease and excluded from Latest.

## Runner

Use a dedicated Apple silicon Mac with the versions in `config/toolchain.env`,
the installed Tart Packer plugin, jq, and the PEM bundle configured by
`IMAGE_CACERT`. The host macOS version must meet the selected profile's minimum.
Xcode builds require the exact XIP archive in `~/XcodesCache`.

The hosted authorization job permits only the configured `TRUSTED_ACTOR`
(default `cocoa-xu`), including the person requesting a rerun. It validates the
repository, main revision, configuration, variant, and publication tag before
scheduling the Mac. There are no pull request triggers.

Source checkout uses `actions/checkout@v7` on Ubuntu. The hosted job packages the
source and locked Swift dependency into Git bundles. The Mac receives those
bundles through Actions artifacts, clones them locally, and builds with a local
SwiftPM mirror. Network Git transports are disabled on the Mac.

The Mac job has package-write permission. Registry credentials are confined to
tag checks and uploads. ORAS receives them through stdin and a private temporary
auth file, with an explicit PEM CA bundle. Export and anonymous verification do
not receive registry credentials. Only the hosted Release job gets
`contents: write`.

Repository workflow checks do not restrict other repositories that can schedule
the same runner. Limit the runner's repository access separately and keep control
of changes to workflows and runner configuration.

## Build and publish

Choose the profile, variant, and operation in Actions. For Xcode, also provide its
exact version. Base builds consume the corresponding published vanilla image;
Xcode builds consume the published base. Their source digest is recorded.

- `build` constructs the image, verifies a separate cold boot, and saves the
  verified bundle for possible publication.
- `publish` requires an existing formal Git tag pointing to the selected source
  commit. It builds, verifies, exports, uploads, and verifies the downloaded image
  before creating the GitHub Release.
- `recover-upload` takes a previous run ID and attempt, such as `123456789-1`.
  It validates that run's saved evidence and restores the verified local bundle.
- `recover-release` creates the GitHub Release from already verified publication
  results. It does not schedule the Mac runner.

The pipeline checks for tag collisions before building and again before upload.
After upload, it downloads every blob anonymously, verifies its hash and image
identity, imports it into an isolated Tart home, and checks a cold boot. A new
GHCR package must be public for this acceptance step to pass. Configure package
visibility before retrying publication verification.

The Release contains the exact inputs, result, image specification, OCI manifest,
and publication evidence. Use the digest reference in `image-spec.json` when
consuming a particular image.

## Recovery and cleanup

Recovery verifies the original authorized run, source revision, configuration
hashes, and saved bundle hashes. It preserves the first successful OCI export;
Tart's manifest contains an upload timestamp, so re-exporting the same VM would
change its digest. An existing remote tag is accepted only when its digest
matches that saved export.

Each run has its own Tart home and ownership marker. Cleanup stops its VMs,
checks that their disks are closed, and removes its temporary files. Failed
verification clones are deleted after their logs are saved. Unrelated VMs are
never touched, and automatic Tart pruning remains disabled.

Verified recovery bundles live under `~/.cache/macos-image/verified`. A failed
upload retains the verified bundle and any completed export; successful remote
verification removes them. Small logs and result files are uploaded as Actions
artifacts even when a stage fails.

See [Validation](validation.md) for the checks already completed and the remaining
full workflow acceptance.
