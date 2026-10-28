# Publishing

All new images use MISO. The repository has three manually dispatched workflows:

| Workflow | Purpose |
| --- | --- |
| Build offline macOS images | Build and upload a candidate; Xcode components install in an isolated VM |
| Verify offline macOS images | Download and test a disposable clone on the M5 |
| Publish accepted offline macOS images | Publish the accepted digest and remove its temporary tags |

## Build

Run **Build offline macOS images** from `main`. Select `macos_version` and
`image_type` (`vanilla`, `base`, or `xcode`). Configuration lives under
`config/miso/<macos_version>/`.

Missing parents are built in order: Vanilla → Base → Xcode. Set `parent_run_id`
to reuse a published Vanilla build for Base, or a Base build for Xcode. Its build
artifact must still be available; retention is 30 days.

For consecutive Xcode builds on the same self-hosted runner, set
`keep_parent_image: true` to retain the imported parent. The next build with the
same parent and disk size reuses it without downloading it again. Leave the
option off on the last build to use and then remove that parent. Only one parent
is retained, outside the runner's temporary directory; changing the parent or
disk size replaces it. Other build files are cleaned normally.

For Xcode, select a configured `xcode_version`, such as `27.1-rc`, and
`xcode_flavor: full` or `slim`. Set the repository secret `XCODE_BASE_URL` to the
private download base URL. The configured Apple archive filename is appended.

To replace Android in an existing Xcode image, set its build as `parent_run_id`
and set `xcode_tools: android`. The parent must be a completed, never-booted MISO
image. Set `xcode_tools: components` to replace legacy simulator installations
with Xcode-managed components. This mode also accepts a native Xcode parent and
uses an ordinary Tart clone, without importing it as an unbooted MISO bundle.
Both paths require VM acceptance.

macOS, Base, the Xcode application, and developer tools are assembled offline.
An isolated builder replaces legacy simulator copies with Apple's managed
installations. It runs `xcodebuild -downloadPlatform` and `-downloadComponent` commands, using
the configured runtime builds and arm64 architecture. It waits for installation
transactions to finish, verifies one available installation per runtime, and
shuts down before export. This stage needs a running VM slot but no VNC interaction.
The final Xcode image is not an unbooted MISO source for subsequent offline edits.

Build artifacts retain the intermediate `offline-source-manifest.json` and
`offline-export.json` separately from the native component receipt. Their disk
hashes describe the offline intermediate, not the final, booted Xcode image.

Vanilla and Base use hosted Apple silicon runners. Xcode uses the M5 runner with
administrator access through `sudo -n` or the authorized `MISO_ROOT_COMMAND`
repository variable for offline assembly. Component-only refresh and VM acceptance
run as the ordinary runner user. Registry transfers use 4 concurrent requests on hosted
runners and 8 on the M5, unless `MISO_TRANSFER_CONCURRENCY` overrides them.

## Verify

After a successful build, run **Verify offline macOS images** with its
`build_run_id` and matching version, image type and Xcode flavor. The
`image-acceptance` environment requires Cocoa or a repository administrator to
approve the M5 job.

The job downloads the candidate once, boots a disposable clone, runs functional
checks, stops the VM and uploads logs and an acceptance record. Download progress
and test output are visible in CI. Xcode acceptance starts its runtime checks as
soon as first-boot SSH connects: it installs and launches an iOS app, runs XCTest
on the simulator, and repeats after at least 11 minutes. Runtime inventory and
paths are monitored throughout. This does not delay the image's readiness signal.

Review the acceptance artifact, including diagnostics, then commit its
`evidence/acceptance.json` under `config/miso/<macos_version>/`:

- `acceptance-vanilla.json` or `acceptance-base.json`
- `acceptance-xcode-<xcode_version>.json` for full Xcode
- `acceptance-slim-xcode-<xcode_version>.json` for Slim Xcode

## Publish

Run **Publish accepted offline macOS images** with matching inputs. It verifies
the committed acceptance record, publishes the recorded digest and removes the
build's temporary candidate tags.

Vanilla and Base tags use the macOS version, such as `27.0.1`. Xcode tags include
both versions, such as `27.0.1-xcode27.1-rc`. Slim uses the same tag in the separate
`macos-golden-gate-slim-xcode` package. No CI run suffix remains on the formal tag.

The workflow refuses to replace an existing version tag with a different digest.
Published images can be downloaded with any compatible OCI client, including Tart.
See [Validation](validation.md) for historical releases and retained evidence.

### Publish a locally accepted image

For an image already built and accepted on the self-hosted Xcode runner, prepare
`~/.local/share/macos-image/publications/<id>/` and dispatch the same publication
workflow with `local_publication: <id>` and matching image/profile inputs. This
uploads the existing image with the job's package permission, without rebuilding,
booting a VM or requiring a personal registry token.

The private directory contains:

- `source-directory.txt`: the absolute path to the accepted Tart-compatible image.
- `source-state.txt`: the accepted source's `stat -f '%i %z %b %.9Fm %.9Fc'` output
  for `disk.img`, `nvram.bin`, then `config.json`. Capture this state before VM
  acceptance and confirm it remains unchanged afterward. Never refresh the record
  to admit a modified source.
- `acceptance.json`: the reviewed local acceptance record, with `target`, `variant`
  (`vanilla`, `base`, `xcode` or `xcode-slim`), `customTag`, `misoVersion`, `prerelease`,
  `reviewAccepted: true`, and the successful `runtime` result including its check
  names. Xcode records also contain `xcodeConfiguration` and the completed
  `componentInstallation` receipt; `parentReference` is optional.

Run `bash ci/publish-local-image.sh --check` with the matching workflow environment
to validate the record and source locally before dispatch. Local publication
requires completed acceptance and refuses tag replacement. It retains each upload
attempt, verifies the anonymous manifest and configuration, and writes
`publication.json` only after verification. A retry can reuse a matching upload
receipt without transferring the image again. The published receipt is also saved
as a workflow artifact; source paths and private input URLs are not included.
