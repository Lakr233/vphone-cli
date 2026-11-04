# Sharing disk space between VMs

`vm rebase` makes a stopped VM store its identical disk blocks once with another VM's, or with a template's. Use it on machines restored without a template, or imported, to win back disk space.

Two VMs restored separately from the same IPSW share nothing on disk, although much of their disk images is the same: two iOS 27.0 iPhones hold about 8.6 GB of identical bytes at the same places in their roughly 20 GB of data, mostly the system volume.

## Rebase a VM

1. Stop both machines. They must be on the same APFS volume.
2. Check what a rebase would save:

   ```sh
   vphone-cli vm rebase second --onto first --dry-run
   ```

3. Rebase, onto a VM or onto a template:

   ```sh
   vphone-cli vm rebase second --onto first
   vphone-cli vm rebase second --onto 3f2a91c0d4e7
   ```

`--onto` takes a VM name or a template identifier (or a unique prefix of one) from `vm template list`; a VM wins when a name matches both. `--dry-run` reports what would be shared and written without writing anything.

The volume needs free space for the blocks that are written until the old image is released.

## What it does

The rebase rebuilds `second`'s disk image from an APFS clone of the base's and writes in only the blocks that differ. Every byte is compared with the original before the image is replaced, so the guest sees exactly the same disk.

Only the disk image changes: `SEPStorage`, `nvram.bin`, `config.plist` and the device identity stay as they are. Rebasing onto a template leaves the template as it is, and the VM does not become one of its clones: `vm template show` does not list it.

## Reading the result

The saving is the **newly shared** figure. Bytes that are identical but already the same blocks on disk are reported as **already shared**, and rebasing them frees nothing.

VMs made by `vm create` from one template already share its blocks, so rebasing one onto another, or onto that template, frees little. The command says so before it compares, and again when the saving is under 0.1 GB. The VMs worth rebasing are ones restored without a template (`--no-template`) or imported.

## Things to know

- The space comes back only when nothing else holds the old image's blocks. Snapshots of the VM, and clones made from it, keep them; delete those first or expect no saving.
- `du` and Finder still count each image at its full size. Free space on the volume (`df`) is the honest measure.
- The two images drift apart again as either VM writes to its disk. A base that is never booted, such as a template, stays the best base, and rebasing again later recovers what drifted.
- A rebase that is interrupted leaves the VM unchanged and may leave a hidden `.rebase-*` folder in it; delete that folder.

## See also

- [Templates](templates.md)
- [Snapshots](snapshots.md)
- [Library, firmware and backups](library-and-backups.md)
