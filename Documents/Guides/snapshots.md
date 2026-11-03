# Snapshots

[Documentation](../README.md) · [Create a VM](create-and-run.md) · [Troubleshooting](troubleshooting.md)

A snapshot saves a stopped VM's disk and boot state so you can return to it
later: take one after a clean install, try something destructive in the guest,
then revert.

```sh
vphone-cli vm snapshot create myphone clean --note "fresh install"
vphone-cli vm snapshot list myphone
vphone-cli vm snapshot revert myphone clean
vphone-cli vm snapshot delete myphone clean
```

`revert` and `delete` ask before they change anything; `--force` skips the
question. A revert keeps the snapshot, so you can go back to it again.
`list --json` prints an array of `{"name", "created", "note"}` objects, oldest
first, with `created` in ISO 8601 and `note` left out when there is none.

## Stop the VM first

`create` and `revert` refuse while the VM is running, and so does anything that
holds its disk image, `SEPStorage` or `nvram.bin` open. Stop it with
`vphone-cli vm stop myphone` or from its window, then try again. The refusal
names each process holding them; when none of them runs the VM (a backup tool,
Spotlight), it says so, and the retry succeeds once that process closes them.

The three files move together. The Secure Enclave's anti-replay counters live in
`SEPStorage`, and the disk holds the matching state. A disk from one moment with
a `SEPStorage` from another makes the SEP panic on the next boot, so a snapshot
always takes all three at once and a revert always puts all three back.

A revert is all or nothing. If it fails partway, it puts the VM's own files
back and reports the error, so the VM is as it was. In the rare case that
putting them back fails too, the error says so: revert to a snapshot again
before starting the VM. A snapshot whose `Snapshot.plist` does not list all
three files, or lists a file that is not part of a snapshot, is refused as
damaged before anything changes.

`list` and `delete` work while the VM runs; neither touches its live files.

## What a snapshot holds

| Captured | Why |
| --- | --- |
| The disk image (`Disk.img`) | The guest's system and data |
| `SEPStorage`, `nvram.bin` | Secure Enclave state and the boot chain's NVRAM, which must match the disk |
| `PatchReceipt.plist` | Which patches are live in the guest |
| `restore-info.json` | The iOS version on the disk, and whether `cfw install` finished |

The last two are taken when present. If one did not exist when the snapshot was
taken, a revert removes it, so the records describe the restored disk rather
than a later install.

Not captured, and unchanged by a revert:

- `config.plist`: the device identity, CPU, memory, network and other settings.
  Change them with `vm config` whenever you like; a revert does not undo that.
- Patch choices (`PatchSelection.plist`), the restore tree, `FirmwareOriginals/`
  and the ROMs. These are inputs on the Mac, not guest state.
- `launchpad.json`. Launchpad saves its own copy in the snapshot folder and puts
  it back itself. The CLI keeps any extra file in a snapshot folder untouched and
  deletes it with the snapshot.

## Disk space

Snapshots live in `<vm>/Snapshots/<name>/` as APFS clones. Taking one is instant
and costs no space; the VM and its snapshots share every block until the guest
writes to it, and then only the changed blocks take new space. Because of this,
`du` and Finder count each snapshot at the full size of the disk and overstate
what it really uses. Free space on the volume is the honest measure.

A snapshot keeps the disk blocks it was taken with. `vm rebase`, which makes a
VM share identical blocks with another VM's, frees nothing while a snapshot of
that VM still holds the old ones; see
[Sharing disk space between VMs](sharing-disk-space.md).

The VM must be on an APFS volume. Elsewhere `create` refuses rather than copying
a disk image that can be tens of gigabytes.

## Clones and exports

`vm clone` and `vm export` leave snapshots behind: a clone or an imported VM
starts with none. Deleting or renaming a VM takes its snapshots with it.
