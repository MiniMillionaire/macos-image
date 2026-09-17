# macOS 27

The clean macOS 27.0 (26A428) build and independent clone/reboot verification
passed on September 11, 2026, on the macOS 27.0 (26A5425a) Apple M4 Pro host with
24 GiB of memory. The build used revision `ac16dfd`, Tart 2.36.0, Packer 1.16.0,
Go 1.25.0, and Tart Packer plugin 1.21.0.

## Clean validation

The commands below use the current profile name.

```sh
IMAGE_CONFIG=config/golden-gate-27.0.env ./scripts/image build vanilla 90s macos-27.0-26A428-clean-e2e-20260911-04
IMAGE_CONFIG=config/golden-gate-27.0.env ./scripts/image import vanilla macos-27.0-26A428-clean-e2e-20260911-04 macos-27.0-26A428-verify-20260911-04
```

The build completed with exit status 0 in 550 seconds. The independent clone
verification completed with exit status 0 in 24 seconds. Both used the production
scripts without screenshots, OCR, image interpretation, or manual repair.
External process deadlines were two hours for the build and 15 minutes for
verification. The verified source is stopped and retained. The temporary
verification clone and downloaded restore cache were deleted afterward at the
user's request; logs were retained.

Local logs:

- `/tmp/macos-image-27-research/clean-e2e-04.log`
- `/tmp/macos-image-27-research/verify-04.log`

| Check after clone and reboot | Verified value |
| --- | --- |
| macOS version and build | 27.0, 26A428 |
| Architecture | arm64 |
| Account and full name | admin, admin |
| SSH development password | admin |
| Locale and preferred language | en_US, en-US |
| Keyboard layout | U.S. |
| Timezone | GMT |
| Automatic console login | admin |
| Setup Assistant | Completed and not running |
| VoiceOver | Not running |
| Gatekeeper | assessments disabled |
| Command Line Tools | Xcode 27.0, active developer directory and clang found |

The installed update label was `Command Line Tools for Xcode 27.0-27.0`.
The active developer directory was `/Library/Developer/CommandLineTools`.
This validation covers the vanilla image; base and Xcode layers have separate
provisioning and verification workflows.

## Restore image

Apple [released macOS 27.0](https://developer.apple.com/news/releases/) on
September 14, 2026, using the same 26A428 build as the RC. The configuration pins the
[Apple IPSW](https://updates.cdn-apple.com/2026FallFCS/afcfc88e-bbe6-44bf-a5da-07c56eebc06c/UniversalMac_27.0_26A428_Restore.ipsw).

- Size: 26,626,436,228 bytes
- SHA-256: `2a5d3c695d501022b7fad9adaffcf2627bcb867d993fb5662dcd41bac99a2836`
- Restore and build manifests: macOS 27.0, build 26A428, VirtualMac2,1 supported

On September 17, the complete release IPSW was downloaded from the URL listed in
Apple's [restore catalog](https://mesu.apple.com/assets/macos/com_apple_macOSIPSW/com_apple_macOSIPSW.xml).
Its size and SHA-256 matched the original RC build inputs; its SHA-1 also
matched the catalog. The release uses the same IPSW bytes, so the existing image
does not need rebuilding.

The Virtualization framework's latest-supported catalog request failed with
`VZErrorDomain` 10001, but the pinned CDN download and VM installation succeeded.
Builds use the fixed URL and do not query the latest-supported catalog.

## Native provisioning

Apple's [guest provisioning API](https://developer.apple.com/videos/play/wwdc2026/224/)
requires both host and guest macOS 27 and applies only on the first boot after
restore. Tart 2.36.0 exposes these settings through `--provisioning-opts`.
The [Tart Packer plugin 1.21.0](https://github.com/cirruslabs/packer-plugin-tart/blob/v1.21.0/builder/tart/step_run.go)
passes `run_extra_args` directly to Tart. The native stage disables VNC.

The first mapping VM, `macos-27.0-26A428-map-20260911-01`, received:

```text
fullName=admin,username=admin,password=admin,logsInAutomatically=true,enablesRemoteLogin=true
```

Read-only SSH inspection immediately after first boot confirmed the exact OS
build, UID 501, full name `admin`, password authentication, automatic console
login, and the completed Setup Assistant marker. No Setup Assistant UI input
was needed.

The initial locale was `en_US`, but `AppleLanguages` was absent and the user's
HIToolbox preferences were empty. The native API has no language or keyboard
options. The preparation script therefore explicitly writes standard English
(`en-US`), region `en_US`, and U.S. enabled/selected/current keyboard preferences.
Installation and first boot also use an isolated English preferences directory;
host preferences are not changed.

The native account becomes available over SSH before its initial preference
migration finishes. A clean build's unified log showed
`InternationalSupportMigrator` replacing the requested `en-US` with the system
fallback list while `AppleLanguagesSchemaVersion` was 0, then setting the schema
to 5400. `defaults read` can return the schema value even when the user's plist
does not exist, so it cannot establish completion. Preparation now reads the
schema directly from the user's `.GlobalPreferences.plist`, waits up to two
minutes for 5400, and confirms the console user before writing the language
preferences. A fresh restore followed by the native stage and a separate reboot
preserved `en_US`, `en-US`, and the integer U.S. keyboard entries with this check.

Keyboard preferences are constructed with typed JSON through `plutil` and
imported as a plist. OpenStep dictionary literals had stored layout ID 0 as a
string; HIToolbox later substituted ABC for the invalid enabled source.
The new plist preserves an integer ID in every U.S. source entry.

## Gatekeeper

`sudo spctl --global-disable` returned a message requiring confirmation in
System Settings, and `spctl --status` remained `assessments enabled`.
The request exits with status 1 while confirmation is pending. A separate debug
clone confirmed the exact output and exit code. Issuing the request in the
native preparation stage was insufficient: after the clean build restarted,
the menu had no Anywhere option. The fixed sequence now issues the request in
Terminal immediately before opening System Settings, in the same boot as the
confirmation. The later SSH stage requires `assessments disabled`.
Development screenshots established the macOS 27 controls on the fixed
2048 by 1536 framebuffer. After scrolling to the bottom of Privacy & Security,
the application-source menu is at `(1676, 796)`. Selecting Anywhere requires
the `admin` password and confirmation at `(1024, 954)`. SSH then reported
`assessments disabled`.

The production sequence is fixed and uses no screenshots or OCR. It runs after
a restart so the explicit language and keyboard preferences have taken effect.
The controller checks display-size metadata before input and imposes its
existing 30-minute phase deadline. Native SSH readiness is limited to ten
minutes, preparation to five minutes, and CLT installation to 45 minutes.

The revised sequence passed on a settled diagnostic account through the
production controller's complete VM start/stop path. A further reboot preserved
disabled Gatekeeper, `en_US`,
`en-US`, automatic login, and integer U.S. layout IDs in the enabled and selected
input-source entries. The check used no screenshots or manual repairs.

After correcting the migration check, a fresh lifecycle mapping also opened
Privacy & Security on the first URL request, exposed Anywhere at the existing
coordinates, and completed both confirmation dialogs. Read-only SSH confirmed
disabled assessments and the requested language and keyboard. The separate
clean production build then passed the Gatekeeper assertion after restart,
followed by the independent clone verification recorded above.

Local mapping logs and screenshots are in `/tmp/macos-image-27-research`.
Mapping and debug VMs were deleted at the user's request after their evidence
was collected. No host Keychain access was performed.
