# `vphone-intg-update` — where this got to

> 2026-09-23. Branch off `qof-update-26-fall` @ `6d5ce7d`, pushed.
>
> Plan: `~/Desktop/vphone-cli-migration-plan.md`, and the approved execution
> order in `~/.claude/plans/mellow-weaving-gem.md`.

## Done

| step | what | state |
| --- | --- | --- |
| S0 | libzstd static in the xcframework? | **yes** — proven at runtime |
| S2 | liblzma MT encoder? | **yes** — 4.84x at 1 GiB |
| 1 | entitlements moved off `vphone-cli` onto `vphone-vm` | done, verified |
| 2 | `vphone-letmein` in, `amfidont` scripts out, docs in 6 languages | done |
| 3 | P0's three Python files | done; two deleted, one kept as reference |
| 4 | `custom-firmware-kit` → `cfw-kit/` | done, as-is |
| 5a | admission gates 1–3 (`make check-aux`) | done; fails on bundled ldid, as designed |
| 5b | `VPhoneArchive` + `vphone-archive` | library and binary done; **call sites not switched** |

Tests: `VPhoneCoreTests` 152/152, `VPhoneArchiveTests` 13/13. The 14
`FirmwarePatcherTests` failures are pre-existing — they need
`ipsws/patch_refactor_input/`, which is not in the repo.

## Needs you, and a machine

Nothing below could be done without root or a real guest.

1. **Can `vphone-vm` start a VM holding the entitlements alone?** Everything
   in step 1 rests on this, and none of it is proven until a guest boots.
2. **`vphone-letmein` end to end** — the sudo prompt, `--hold 10` restoring
   while the guest keeps running, Ctrl-C reaching the guest. The window
   defaults to 10 seconds, which is a guess; measure it.
3. **Location and TouchID**, which depend on TCC attributing the usage
   strings to `vphone-vm`. It is `CFBundleExecutable`, so it should — worth
   confirming rather than assuming.
4. **Bridged networking**, now validated at boot instead of at config time.
5. **`cfw flip-snapshot` against a real `Disk.img`.** The byte comparison
   against the Python passed on a synthetic fixture; repeat it once on a real
   image, then delete `tools/apfs_snap_rename.py`.

## Next, in order

1. **Switch the archive call sites.** `vphone-archive` is built, bundled and
   tested, and nothing calls it yet. The IPSW unzip in `fw_prepare.sh` and the
   host-side temp extractions are low risk. The `$TAR` calls in
   `cfw_install*.sh` are not: they write to a mounted guest volume as root,
   and want the tree-fingerprint comparison (uid/gid, ACLs, xattrs, hardlink
   grouping, `st_blocks`) against GNU tar before being switched. See
   `research/archive_extraction_contracts.md`.
2. **`VPhoneSign`**, which is what clears the last two admission-gate
   failures. `ldid` is the only binary we ship that is already
   non-self-contained. The plan's §3.11 has the measurements; the
   `signcert.p12` needs re-wrapping with a password first, and the old
   empty-password copy has to stay for the `--use-ldid` escape hatch.
3. **`vm export` / `import`** onto `VPhoneArchive`, keeping gnutar, `.tzst`
   at zstd 3 and `.txz` at xz 9, and checking compatibility both ways.
4. **Gate 4** — a machine with no Homebrew. Still the only thing that can
   support "it works elsewhere"; gates 1–3 are necessary and not sufficient,
   which the script says out loud.

## Three things the plan got wrong

Recorded because they were measured, not reasoned about.

- **`ipsw` / `aea` / `ldid` are called by absolute `/opt/homebrew` path from
  Swift**, not through `PATH`. §1.4 counts the shell call sites. Gate 2 lists
  all of them.
- **`sources/vphone.entitlements` has 7 keys**, not the 4 the plan says or the
  5 `CLAUDE.md` said. Two of them — location and BiometricKit — belong to
  `Devices/`, which is why they all landed on `vphone-vm`.
- **The admission rule caught a bug the plan did not predict**: signing
  `vphone-vm` first sealed the bundle over its siblings in an earlier state,
  and `codesign -v` reported "nested code is modified or invalid". The main
  executable is signed last now, and both build paths verify the seal.

## And one I nearly got wrong

The first measurement of `--no-overwrite-dir` said libarchive already leaves
an existing directory's mode alone, which would have made the flag
decorative — and it was taken from an extraction that was failing partway and
applying nothing. A measurement from a failing code path measures the failure.
It is 0700 in, 0777 out when extraction actually works, and the flag matters.
