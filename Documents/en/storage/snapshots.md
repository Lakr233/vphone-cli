# Snapshots

A snapshot saves a stopped machine's disk and boot state so you can return to it later. Take one after a clean install, try something destructive in the guest, then revert.

## Take, list, revert and delete

1. Stop the machine: `vphone-cli vm stop myphone`, or close it from its window.
2. Take a snapshot, then work in the guest. When you want the saved state back, stop the machine again and revert.

```sh
vphone-cli vm snapshot create myphone clean --note "fresh install"
vphone-cli vm snapshot list myphone
vphone-cli vm snapshot revert myphone clean
vphone-cli vm snapshot delete myphone clean
```

- `revert` and `delete` ask before they change anything; `--force` skips the question.
- A revert keeps the snapshot, so you can go back to it again.
- `list --json` prints an array of `{"name", "created", "note"}` objects, oldest first, with `created` in ISO 8601 and `note` left out when there is none.
- `list` and `delete` work while the machine runs; neither touches its live files.

## When create or revert refuses

`create` and `revert` refuse while the machine is running, and while any process holds its disk image, `SEPStorage` or `nvram.bin` open. The refusal names each process holding them. When none of them runs the machine (a backup tool, Spotlight), it says so, and the retry succeeds once that process closes the files.

`create` also refuses when the machine is not on an APFS volume, rather than copying a disk image that can be tens of gigabytes.

A snapshot whose `Snapshot.plist` does not list all three state files, or lists a file that is not part of a snapshot, is refused as damaged before anything changes.

A revert is all or nothing. If it fails partway, it puts the machine's own files back and reports the error, so the machine is as it was. In the rare case that putting them back fails too, the error says so: revert to a snapshot again before you start the machine.

## What a snapshot holds

| Captured | Why |
| --- | --- |
| The disk image (`Disk.img`) | The guest's system and data |
| `SEPStorage`, `nvram.bin` | Secure Enclave state and the boot chain's NVRAM, which must match the disk |
| `PatchReceipt.plist` | Which patches are live in the guest |
| `restore-info.json` | The iOS version on the disk, and whether `cfw install` finished |

The disk, `SEPStorage` and `nvram.bin` always move together. The Secure Enclave's anti-replay counters live in `SEPStorage`, and the disk holds the matching state; a disk from one moment with a `SEPStorage` from another makes the SEP panic on the next boot.

`PatchReceipt.plist` and `restore-info.json` are taken when present. If one did not exist when the snapshot was taken, a revert removes it, so the records describe the restored disk rather than a later install.

Not captured, and unchanged by a revert:

- `config.plist`: the device identity, CPU, memory, network and other settings. Change them with `vm config` whenever you like; a revert does not undo that.
- Patch choices (`PatchSelection.plist`), the restore tree, `FirmwareOriginals/` and the ROMs. These are inputs on the Mac, not guest state.
- `launchpad.json`. Launchpad saves its own copy in the snapshot folder and puts it back itself. The CLI keeps any extra file in a snapshot folder untouched and deletes it with the snapshot.

## Disk space

Snapshots live in `<vm>/Snapshots/<name>/` as APFS clones. Taking one is instant and costs no space: the machine and its snapshots share every block until the guest writes to it, and then only the changed blocks take new space. `du` and Finder count each snapshot at the full size of the disk and overstate what it uses; free space on the volume is the honest measure.

A snapshot keeps the disk blocks it was taken with. `vm rebase` frees nothing while a snapshot of that machine still holds the old blocks; see [Sharing disk space between VMs](sharing-disk-space.md).

## Clones, exports, renames

`vm clone` and `vm export` leave snapshots behind: a clone or an imported machine starts with none. Deleting or renaming a machine takes its snapshots with it.

## See also

- [Library, firmware and backups](library-and-backups.md)
- [Sharing disk space between VMs](sharing-disk-space.md)
- [Troubleshooting](../help/troubleshooting.md)
