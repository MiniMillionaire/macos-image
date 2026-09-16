# Expanding a downloaded image

For a stopped local image, prepare a larger clone before using it:

```sh
.build/release/macos-image resize macos-sequoia-15.6.1-vanilla \
  --target sequoia-work --disk-size 160
tart run sequoia-work
```

The target must be a new name. The command preserves the source, moves the
clone's Recovery partition while it is stopped, expands APFS in the guest,
checks the usable capacity, and verifies a separate cold boot. It preserves
the source VM's CPU, memory and display settings. The source must be stopped,
and the requested size must exceed its current disk size.

Use `--config` when the source uses another image definition. Verification
requires the source's macOS version and build to match that configuration.
The current command supports raw disks with the image's iBoot, system APFS and
Recovery partition layout. It does not support ASIF disks or shrinking.

Sizes are decimal GB, as in Tart. A 160 GB disk is about 149 GiB. Recovery,
iBoot and filesystem overhead consume part of that capacity.

## Why `tart set` alone is insufficient

Tart 2.36.0 increases the raw disk file's length when given `--disk-size`.
It does not move partitions or expand the guest filesystem. These images keep
Recovery after the system APFS partition, so newly added space is beyond
Recovery and cannot be used by `diskutil apfs resizeContainer ... 0` alone.

Vanilla has no guest agent. Base and Xcode install
[`openai/tart-guest-agent`](https://github.com/openai/tart-guest-agent), whose
resize code repairs the partition map and expands adjacent APFS space. It does
not relocate Recovery. Xcode builds already relocate Recovery when growing
their disk, but a subsequent size increase encounters the same boundary.

The resize command uses the existing pinned Tart Packer plugin's offline
Recovery relocation. A guest-agent fork alone would not fix the current
partition layout. Supporting this directly in `tart set` and `tart run` would
require a host-side Tart change or another independently verified method.
See [Tart's disk resizing FAQ](https://tart.run/faq/#disk-resizing).

## Validation

The September 17, 2026 experiment used the published Sequoia vanilla digest
`sha256:37db3b09d4877a2522adc80aa944f91cc3f9f659cde65af8c4d405e43e4e15f3`.

| Check | Result |
| --- | --- |
| Bare Tart resize | 160 GB disk, 74.1 GB APFS, 80 GB unused |
| Offline relocation and guest expansion | 154,107,002,880-byte system APFS |
| Mounted Data filesystem capacity | 154,107,002,880 bytes |
| Recovery | Same UUID, size and complete content hash; filesystem check passed |
| Independent normal boot | macOS 15.6.1 / 24G90; vanilla verification passed |
| Account and encryption | `admin` retained volume ownership; FileVault off |

RecoveryOS boot itself was not tested. Base and Xcode were inspected through
their recipes and the agent source; their published images were not downloaded
for this experiment. Published Sequoia and Tahoe Xcode disks are already
180 GB and 220 GB respectively, so 160 GB would be a shrink for those images.
