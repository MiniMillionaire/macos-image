# Disk shrink validation

These experiments ran on September 18, 2026 on an Apple silicon host with
macOS 27.0 and Tart 2.32.1. Each one used a disposable clone of a published
image. They check the policy in [Disk size](disk-size.md#build-and-published-sizes):
build on a sparse 256 GB disk, then shrink with `diskutil image resize` to the
smallest multiple of 10 GB that leaves at least 8 GiB free, keeping Recovery.

The published images were built with the earlier fixed sizes. A fresh 256 GB
build may report a slightly different minimum.

## Results

| Image | Published disk | diskutil minimum | Policy size | Free after boot | Verification |
| --- | --- | --- | --- | --- | --- |
| `macos-golden-gate-xcode:27` | 220 GB | 87.3 GB | 100 GB | 15 GiB | `verify-image.sh` xcode passed |
| `macos-golden-gate-vanilla:27.0` | 80 GB | 40.9 GB | 50 GB | 9.2 GiB | `verify-image.sh` vanilla passed |
| `macos-tahoe-xcode:26.6` | 220 GB | 92.2 GB | 110 GB | 18 GiB | `verify-image.sh` xcode passed |
| `macos-tahoe-vanilla:26.6.2` | 80 GB | 33.8 GB | 50 GB | 16 GiB | `verify-image.sh` vanilla passed |

Digests:

- Golden Gate Xcode 27: `sha256:4bdf7fd662476fcabea8168377916f345229dd38c3cae50b1a6436ea113153b3`
- Golden Gate vanilla 27.0: `sha256:a2883aa8087c07b452a56a6c441a69e7064384bb662004c610e293c900aa11ce`
- Tahoe Xcode 26.6: `sha256:d1257eec6bb3c52e37bc77dbf974e38c4862e7dbd8cb9bc30c5417079b38bd25`
- Tahoe vanilla 26.6.2: `sha256:86777a3e30fcbba7d8fe6aeb43adbab33e9cecbc249c3ccdf26b17511ff0f8ba`

The vanilla and Tahoe Xcode runs used the `shrink_vm` function from
`scripts/image`. It was extracted with its helpers, and `run_bounded` called
each command directly. The Golden Gate Xcode run executed the same `diskutil`
commands by hand. The Tahoe Xcode run used Tart 2.36.0.

## Golden Gate Xcode 27

Read-only attachment of the published disk showed 79.7 GB in use in the
214.1 GB APFS container:

| Volume | Consumed |
| --- | --- |
| System | 13.7 GB |
| Preboot | 10.7 GB |
| Recovery (in the system container) | 1.5 GB |
| VM | 1.1 GB |
| Data | 52.6 GB |

Data included 21.5 GiB of simulator runtimes: iOS 7.5, visionOS 7.0,
watchOS 3.6 and tvOS 3.4. Flutter used 4.0 GiB, the Android SDK 3.3 GiB,
Homebrew 3.0 GiB and Xcode 27.0 3.3 GiB.

The disk has the following partitions:

| Partition | Offset (bytes) | Size (bytes) |
| --- | --- | --- |
| `Apple_APFS_ISC` | 20,480 | 524,288,000 |
| `Apple_APFS` | 524,308,480 | 214,107,004,928 |
| `Apple_APFS_Recovery` | 214,631,314,944 | 5,368,668,160 |

Fixed overhead is therefore about 5.9 GB. A disk of N GB gives an APFS
container of about N − 5.9 GB.

`diskutil image resize --size 100g` on the stopped clone took 5.4 seconds.
It shrank APFS to 94.1 GB, moved Recovery to the new end, rewrote the backup
GPT and truncated the file:

| Check | Result |
| --- | --- |
| File length | 100,000,002,048 bytes |
| Host allocation | 83.5 GB (the moved Recovery is written densely) |
| `tart list` disk size | 100 |
| Normal boot | macOS 27.0 (26A428), session `C303DE6C-E588-4492-8704-1AF4422637B6` |
| `verify-image.sh` (xcode) | Passed; Flutter reports Chrome missing, as expected |
| Data | 88 GiB size, 49 GiB used, 15 GiB available |
| Recovery container | `diskutil verifyVolume` passed |
| SIP | Disabled, unchanged |
| Simulator runtimes | iOS, tvOS, watchOS and visionOS 27.0 all Ready |

Growing the disk with the same command also worked:

- 100 to 120 GB took 4.2 seconds. APFS reached 114.1 GB and Data had 33 GiB
  available after boot. All four runtimes were still present.
- 120 to 256 GB was refused with `Requested size exceeds maximum size`. The
  limits reported a maximum of 146,006,921,216 bytes, which is the current
  size plus about 100 GiB of host free space. Builds therefore grow disks with
  Tart and Packer.
- Applying the policy from 120 GB gave a 86,138,421,248-byte minimum, which
  sets a 100 GB target. The shrink took 4.7 seconds and host allocation
  stayed at 83.3 GB.

### RecoveryOS

The clone was booted with `tart run --recovery` after diskutil had moved its
Recovery partition several times. VNC input selected Options, and the Recovery
window appeared. It offered Restore from Time Machine, Reinstall macOS 27
Golden Gate, Web Browser and Disk Utility.

## Golden Gate vanilla 27.0

`shrink_vm` read a minimum of 40,890,269,696 bytes and shrank the disk to
50 GB in 5 seconds:

| Check | Result |
| --- | --- |
| File length | 50,000,003,072 bytes |
| Host allocation | 39.4 GB |
| Normal boot | macOS 27.0 (26A428), session `BCD227FF-18B0-4B95-BF4B-C430806F56DE` |
| `verify-image.sh` (vanilla) | Passed: account, locale, keyboard, time zone, automatic login, Gatekeeper, Command Line Tools |
| APFS container | 44.1 GB |
| Data | 41 GiB size, 7.7 GiB used, 9.2 GiB available |
| Recovery container | `diskutil verifyVolume` passed |
| SIP | Enabled, as expected for vanilla |

## Tahoe Xcode 26.6

`shrink_vm` read a minimum of 92,178,219,008 bytes and shrank the disk from
220 GB to 110 GB in 8 seconds:

| Check | Result |
| --- | --- |
| File length | 110,000,001,024 bytes |
| Host allocation | 85.6 GB before, 89.7 GB after |
| Normal boot | macOS 26.6.2 (25G83), session `0F95DD72-292B-479A-A669-D2A89A35BBB2` |
| `verify-image.sh` (xcode) | Passed: Xcode 26.6, Flutter and Android SDK 36; Chrome missing, as expected |
| APFS container | 104.1 GB |
| Data | 97 GiB size, 59 GiB used, 18 GiB available |
| Recovery container | `diskutil verifyVolume` passed |
| SIP | Disabled, unchanged |
| Simulator runtimes | 4 images, 21.8 GB |

## Tahoe vanilla 26.6.2

`shrink_vm` read a minimum of 33,793,507,328 bytes and shrank the disk to
50 GB in 5 seconds:

| Check | Result |
| --- | --- |
| File length | 50,000,003,072 bytes |
| Host allocation | 28.3 GB before, 32.4 GB after |
| Normal boot | macOS 26.6.2 (25G83), session `59248942-85FB-437F-ADBD-A3971D1108B8` |
| `verify-image.sh` (vanilla) | Passed |
| APFS container | 44.1 GB |
| Data | 41 GiB size, 5.4 GiB used, 16 GiB available |
| Recovery container | `diskutil verifyVolume` passed |
| SIP | Enabled, as expected for vanilla |

## Disabling SIP after the shrink

On both shrunk vanilla images, `tart run --recovery` reached the startup
options picker, which the Recovery boot displays. The `csrutil disable`
keystrokes from `templates/disable-sip.pkr.hcl` were then replayed with the
repository's VNC controller, using an added arrow-key mapping. The picker
ignored the input with Tart 2.32.1 and with Tart 2.36.0, at key intervals of
200 ms and 300 ms. Reconnecting to Tart's experimental VNC server made Tart
exit with status 133.

As a control, the unshrunk published Tahoe vanilla ran the same sequence with
Tart 2.36.0 and showed the same result. The failure is therefore in this local
input path, not in the shrunk disk. The controller did select Options on the
Golden Gate Xcode clone once, and that clone reached the Recovery window.

CI disables SIP through Packer's `boot_command`. The first base or Xcode build
from a shrunk vanilla runs that step against a moved Recovery partition.

## Online shrink and manual GPT move

This earlier method is kept for reference. The Golden Gate Xcode clone was
booted, and `diskutil apfs resizeContainer disk0s2 90107002880B` shrank the
booted container from 214.1 GB to 90.1 GB in 17 seconds. Its limits were a
84.4 GB minimum and a 95.1 GB recommended minimum. Local snapshots: none.

With the VM stopped, a script moved Recovery to the new end and rewrote the
primary GPT, backup GPT and protective MBR. It then truncated `disk.img`
from 220 GB to 96 GB in 5.4 seconds.

- The Recovery SHA-256 was unchanged:
  `49670bad609ed2375955ffd2a0bbf10061c6ec384679364232bd9a50f2c426a0`.
- The partition UUIDs were unchanged.
- The VM booted normally. Xcode 27.0 and all four runtimes were present, and
  Data had 11 GiB free.

`diskutil image resize` does the same work in one command, so the script is
not part of the repository.

## Host space

Guest deletions return space to the host. The host allocation of `disk.img`
was 79,450 MB. After writing 4 GiB in the guest it was 83,768 MB. Within 10
seconds of deleting the file and running `sync`, it was 79,474 MB.

An Apple engineer confirms that Virtualization framework keeps disk images
sparse when the guest issues TRIM
([forum](https://developer.apple.com/forums/thread/739477)).

The logical disk size costs almost nothing to download. The 220 GB image has
410 disk layers. 252 of them are identical zero chunks that share one
3,260,420-byte blob.

## Tool behavior

These notes come from source inspection:

- Tart 2.36.0 refuses to shrink a raw disk. If the size is equal it does
  nothing; if it is larger it extends the file
  ([`VMDirectory.swift`](https://github.com/openai/tart/blob/2.36.0/Sources/tart/VMDirectory.swift#L287-L301)).
  A raw disk's size is the length of the file.
- The Tart Packer plugin 1.21.0 `relocate` only moves Recovery to the end of
  a larger file. It reports "Nothing to relocate" when Recovery is already at
  the end
  ([`relocate.go`](https://github.com/cirruslabs/packer-plugin-tart/blob/v1.21.0/builder/tart/recoverypartition/relocate.go)).
- `tart-guest-agent` runs `diskutil apfs resizeContainer <disk> 0`, which
  stops at Recovery
  ([`diskresizer.go`](https://github.com/openai/tart-guest-agent/blob/v0.14.2/internal/diskresizer/diskresizer.go#L63-L89)).
- `cirruslabs/macos-image-templates` builds vanilla at 50 GB with Recovery
  kept, base at 50 GB with Recovery deleted, and Xcode at 140 GB or more. It
  does not shrink. Anka documents that a VM disk cannot be downsized.
