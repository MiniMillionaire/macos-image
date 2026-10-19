# macOS images for Tart

This repository builds macOS VM images offline with [MISO](https://github.com/cocoa-xu/miso) and publishes Tart-compatible OCI images to GHCR.

Start **Build offline macOS images** from GitHub Actions.
Select `macos_version` (currently `27.0.1`) and `image_type`:
`vanilla`, `base`, or `xcode`. Missing parents are built once in order,
**Vanilla → Base → Xcode**, on the same runner. Set `parent_run_id` to reuse a previous
Vanilla run for Base, or a Base run for Xcode. Parent artifacts expire after 30 days.

Vanilla and Base use official Apple silicon GitHub runners. Xcode uses the existing
M5 runner; set `xcode_version` to a configuration name such as `27.1-rc` and provide
`XCODE_BASE_URL` as a repository secret. The runner needs administrator access
through `sudo -n` or the `MISO_ROOT_COMMAND` repository variable pointing to its
authorized command runner. MISO expands smaller Base disks while preserving Recovery.
Choose `xcode_flavor: slim` to keep iOS/watchOS and apply native Intel trimming,
compression, cache cleanup and sparse compaction.
To refresh an existing Xcode image without reinstalling its tools, set
`xcode_tools: configuration` and use that Xcode build as `parent_run_id`.

Construction does not start a VM or install Rosetta. After upload, acceptance
downloads the candidate once and boots a disposable clone. Numbered tags follow
successful VM acceptance. The
offline workflow uses MISO for upload and download, without a Tart executable.
Transfers default to 4 concurrent requests on hosted runners and 8 on the M5;
set the `MISO_TRANSFER_CONCURRENCY` repository variable to override this.

For external storage, set `storage_directory` in the build and verification
workflows to the same existing directory on an APFS volume. Alternatively, set
the `IMAGE_STORAGE_DIRECTORY` repository variable for self-hosted jobs. Image
workspaces and retained parents stay on that volume; concurrent runs have separate
workspaces. Leave it empty to use the current runner paths. Keep the volume mounted
through cleanup. Use `keep_parent_image` to reuse a parent across builds, then leave
it off for the last build; `keep_source_image` retains an accepted source for reuse.

For VM acceptance, dispatch **Verify offline macOS images** with the build run ID.
It uses a disposable clone on the M5, displays download and test progress, and
retains its results as an artifact. The `image-acceptance` environment requires
Cocoa or a repository administrator to approve the job before it starts.

macOS 27.0.1 Vanilla, Base and Xcode 27.1 RC (full or Slim) are available:

```shell
tart clone ghcr.io/minimillionaire/macos-golden-gate-vanilla:27.0.1 vanilla
tart clone ghcr.io/minimillionaire/macos-golden-gate-base:27.0.1 base
tart clone ghcr.io/minimillionaire/macos-golden-gate-xcode:27.0.1-xcode27.1-rc xcode
tart clone ghcr.io/minimillionaire/macos-golden-gate-slim-xcode:27.0.1-xcode27.1-rc xcode-slim
```

See [Publishing](docs/releases.md) for the build, acceptance and publication steps.
Previous image releases remain documented in the [validation record](docs/validation.md).
