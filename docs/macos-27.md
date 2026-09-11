# macOS 27

The initial macOS 27.0 RC (26A428) mapping passed on September 11, 2026, on the
macOS 27.0 (26A5425a) Apple M4 Pro host. A clean production build and independent
clone/reboot verification are still pending.

## Restore image

Apple [published the RC](https://developer.apple.com/news/releases/) on
September 9, 2026. The configuration pins the
[Apple IPSW](https://updates.cdn-apple.com/2026FallFCS/afcfc88e-bbe6-44bf-a5da-07c56eebc06c/UniversalMac_27.0_26A428_Restore.ipsw).

- Size: 26,626,436,228 bytes
- SHA-256: `2a5d3c695d501022b7fad9adaffcf2627bcb867d993fb5662dcd41bac99a2836`
- Restore and build manifests: macOS 27.0, build 26A428, VirtualMac2,1 supported

The full downloaded file matched the digest returned by the Apple CDN. The
Virtualization framework's latest-supported catalog request failed with
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

## Gatekeeper

`sudo spctl --global-disable` returned a message requiring confirmation in
System Settings, and `spctl --status` remained `assessments enabled`.
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

Local mapping logs and screenshots are in `/tmp/macos-image-27-research`.
The mapping VM is stopped and retained. No host Keychain access was performed.
