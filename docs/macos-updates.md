# Updating an existing macOS VM

An IPSW creates the initial VM. Later macOS releases can be installed inside
that VM without another IPSW. The macOS 15 starting image remains 15.6.1 / 24G90.

## Build policy

Each official IPSW starts a new set of upgrade builds within its macOS major
version. Build and verify its vanilla image first. Until the next official
IPSW, upgrade each target directly from that vanilla image, pinned by digest.
Do not chain one patch image into the next.

For Sequoia, 15.7.7, 15.7.8, 15.7.9, and 15.8 all start from the 15.6.1 vanilla
image. When a newer official IPSW becomes available, build a new vanilla from
it and use that image for subsequent targets. Existing target configurations
retain their original source digest and installer checksum.

CI builds and publishes targets in order. After one target passes, try the next
through CI; use local clones to investigate failures. A successful local
experiment establishes the recipe, but does not replace the CI build or its
independent cold-boot and anonymous-download acceptance checks.

Each upgrade pins its source version and build, source image digest, target
version and build, and installer URL, size, and SHA-256. A missing exact target
is a failed build, not a reason to install a different release or macOS major.
Base and Xcode images are derived from the matching accepted vanilla version.
Each Xcode combination starts from vanilla and installs its own development
tools; it does not reuse an earlier Xcode image.

Keep the source image's disk size unchanged. Start each target at the standard
capacity and grow only its build clone if the upgrade needs more room. Record
the verified capacity in that target's configuration; its base image inherits
the same size. See the [disk capacity policy](disk-size.md#build-capacity).

After the target boots, remove its installer and temporary files created by
the build before the independent cold boot. Cleanup and post-upgrade Setup
Assistant handling must be verified for the target macOS version. Do not assume
that paths or first-login behavior are shared by every major or patch release.
Keep installer backups outside the guest. Move `latest` only after confirming
that the accepted target is the current release within its macOS major.

## Local investigation

Run the commands below inside a disposable clone. Keep the source image stopped.
On Apple silicon, the account authorizing an update must be a volume owner.
The published Sequoia vanilla image's `admin` account has a secure token and
volume ownership; FileVault is off.

## Choose a version

These two catalogs serve different purposes:

```sh
softwareupdate --list
softwareupdate --list-full-installers
```

On September 17, 2026, the 15.6.1 guest's update list offered 15.8 / 24H23 and
macOS 27. The full-installer list also offered 15.7.7 / 24G720, 15.7.8 / 24G824,
and 15.7.9 / 24G830. An available full installer need not have a matching IPSW
or appear in the incremental update list.

For a fixed version, require an exact catalog match. If Apple no longer offers
it for the guest, stop. Do not substitute another version. Apple's
[installer instructions](https://support.apple.com/en-us/102662) describe these
availability limits.

For the latest release of the current major:

1. Read `sw_vers -productVersion` before scanning and retain its first component.
2. Run a fresh update scan and select only macOS entries with that major version.
3. Compare numeric version components, then retain the exact label and build.
4. Fail on an ambiguous result. Install that one label and verify the resulting
   version and build after restarting.

Do not use `--all` or `--recommended`. Neither `--os-only` nor
`--product-types macOS` restricts the major version. In the observed 15.6.1 scan,
`--product-types macOS` also returned Safari and Command Line Tools entries.
An empty same-major selection is not permission to install a different major.

"Latest" changes over time. Record the selected version, build, source version,
and scan date so that a later fixed-version build can request the same target.

## Install a fixed full installer

The following download was verified inside the VM:

```sh
sudo softwareupdate --fetch-full-installer --full-installer-version 15.7.9
```

This creates `/Applications/Install macOS Sequoia.app`; it does not update the
running OS. Check the app's `Contents/Resources/startosinstall --usage` before
using it. The app's `CFBundleShortVersionString` is the installer version, not
the macOS version. The target OS version and build are recorded in the mobile
software update manifest inside `Contents/SharedSupport/SharedSupport.dmg`.

For this development image's `admin` account:

```sh
printf '%s\n' admin | sudo -n \
  '/Applications/Install macOS Sequoia.app/Contents/Resources/startosinstall' \
  --agreetolicense --forcequitapps --rebootdelay 5 --user admin --stdinpass
```

This installed 15.7.9 / 24G830 from 15.6.1 / 24G90 without UI input. It retained
the account, a test file, locale, keyboard and FileVault state. The installer
removed itself after installation. The 80 GB vanilla VM started with about
47 GiB free; other image variants need their own free-space check.

## Install the selected update

After resolving the latest macOS 15 release to 15.8 / 24H23, the exact command is:

```sh
printf '%s\n' admin | sudo -n softwareupdate \
  --install 'macOS Sequoia 15.8-24H23' \
  --restart --user admin --stdinpass --agree-to-license
```

Use the label from the current guest's scan. Do not construct a label from a
version number and assume that Apple still offers it.

This updated the 15.7.9 guest to 15.8 / 24H23. A fresh scan afterward offered
Safari and macOS 27, but no newer macOS 15 update. The same-major selector
stopped without choosing either entry.

## Verify the restart

Bound the scan, installer and restart waits separately. The experiment allowed
11 minutes for each scan, 75 minutes for installation, and 30 minutes for the
updated guest to return. Restart polling ran every 15 seconds.

An SSH disconnect is expected during restart, but is not an acceptance result.
Check `sw_vers`, require a different `kern.bootsessionuuid`, and check FileVault,
volume ownership, account, language, keyboard and retained data. Then shut down
and perform a separate cold boot with the normal image verifier.

The first login after the full-installer update launched
`Setup Assistant -MiniBuddyYes`. A separate cold boot cleared it and passed
the vanilla verifier without UI input or Setup Assistant preference changes.
The cold-boot check is part of the update procedure.

## Validation

Both paths passed on September 17, 2026, starting from a clone of the published
Sequoia vanilla image at
`sha256:37db3b09d4877a2522adc80aa944f91cc3f9f659cde65af8c4d405e43e4e15f3`.

| Path | Installed version | Independent cold boot |
| --- | --- | --- |
| Exact full installer from 15.6.1 | 15.7.9 / 24G830 | Vanilla profile passed |
| Latest current-major update from 15.7.9 | 15.8 / 24H23 | Vanilla profile passed |

Both retained `admin` with volume ownership, the test file's SHA-256, `en_US`,
`en-US`, the U.S. keyboard and disabled FileVault. No UI input was needed.
The 15.8 update briefly rejected SSH authentication during its first boot;
the original password worked on a later attempt without changing the account.
Require successful guest checks after restart, not just an open SSH port.

These observations apply to the tested Sequoia guest. Catalog availability and
unattended behavior still need checking when adding another macOS major.
