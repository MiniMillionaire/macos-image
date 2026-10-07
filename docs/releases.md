# Publishing

All new images use MISO. The repository has three manually dispatched workflows:

| Workflow | Purpose |
| --- | --- |
| Build offline macOS images | Build and upload a candidate without starting a VM |
| Verify offline macOS images | Download and test a disposable clone on the M5 |
| Publish accepted offline macOS images | Publish the accepted digest and remove its temporary tags |

## Build

Run **Build offline macOS images** from `main`. Select `macos_version` and
`image_type` (`vanilla`, `base`, or `xcode`). Configuration lives under
`config/miso/<macos_version>/`.

Missing parents are built in order: Vanilla → Base → Xcode. Set `parent_run_id`
to reuse a published Vanilla build for Base, or a Base build for Xcode. Its build
artifact must still be available; retention is 30 days.

For Xcode, select a configured `xcode_version`, such as `27.1rc`, and
`xcode_flavor: full` or `slim`. Set the repository secret `XCODE_BASE_URL` to the
private download base URL. The configured Apple archive filename is appended.

Vanilla and Base use hosted Apple silicon runners. Xcode uses the M5 runner with
administrator access through `sudo -n` or the authorized `MISO_ROOT_COMMAND`
repository variable. Registry transfers use 4 concurrent requests on hosted
runners and 8 on the M5, unless `MISO_TRANSFER_CONCURRENCY` overrides them.

## Verify

After a successful build, run **Verify offline macOS images** with its
`build_run_id` and matching version, image type and Xcode flavor. The
`image-acceptance` environment requires Cocoa or a repository administrator to
approve the M5 job.

The job downloads the candidate, boots a disposable clone, runs functional
checks, stops the VM and uploads logs and an acceptance record. Download progress
and test output are visible in CI. Construction itself never starts a VM.

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
