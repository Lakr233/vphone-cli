# VPhoneArchive: what was measured, and what bit

> 2026-09-23, branch `vphone-intg-update`. libarchive 3.8.9 from
> `Lakr233/libarchive.xcframework` 0.1.1, macOS 26 (26A428).
>
> Companion to `research/libarchive_xcframework_validation.md`, which covers
> whether libzstd and the liblzma MT encoder are compiled in. This one is
> about behaviour on disk.

## Why one program replaces four

`gtar`, `bsdtar`, `unzip` and `zstd` all go away. zstd is the one that forces
the issue: **both the system tar and GNU tar shell out to a `zstd(1)` for that
filter**, and libzstd is in neither `/usr/lib` nor the SDK. On a machine
without Homebrew, every `.zst` step of a CFW install fails. Side by side, with
no zstd reachable:

```
$ env -i PATH=/usr/bin:/bin vphone-archive extract -f t.tzst -C out
extracted 5 entries to .../out

$ env -i PATH=/usr/bin:/bin /usr/bin/tar -tf t.tzst
tar: Error opening archive: Can't initialize filter; unable to run program "zstd -d -qq"
```

## `--no-overwrite-dir`: measured, and it corrected me twice

GNU tar has the flag; libarchive has no equivalent, and neither of the two
things it does offer is the same thing.

**First measurement said the flag was unnecessary.** An existing directory's
mode came back unchanged with the flag off, which would have meant
`man 3 archive_write_disk`'s "existing directories will have their permissions
updated" no longer held and `noOverwriteDir` was decorative.

**That reading was wrong, and the way it was wrong is worth remembering.** The
extraction under test was failing partway — `ARCHIVE_EXTRACT_SECURE_NOABSOLUTEPATHS`
was rejecting the rewritten paths — so nothing was being applied to anything.
A measurement taken from a failing code path measures the failure. With
extraction actually working: **0700 in, 0777 out.** The manual is right, and
the flag is load-bearing.

`ARCHIVE_EXTRACT_NO_OVERWRITE` is still not a substitute, and it is wrong in
the opposite direction: it skips *any* existing object, so a regular file that
should be replaced silently is not. Both halves are pinned in tests — files
under a skipped directory still get written, and an existing regular file
still gets replaced.

The implementation is an `lstat` before `archive_write_header` on directory
entries. `lstat`, not `stat`: a symlink pointing at a directory is a symlink,
and leaving it alone is a different decision. Measured: with a symlink planted
where a directory entry would land, `SECURE_SYMLINKS` removes it and creates a
real directory, and nothing is written through it.

## Two macOS path traps

Both cost real time, and both come from the same place: `/tmp` and `/var` are
symlinks into `/private`.

### `SECURE_SYMLINKS` inspects every component of an absolute path

Give it `/var/folders/.../dest/file` and it refuses the whole extraction with
"Cannot extract through symlink /var/...", because `/var` is one. The fix is to
resolve the destination once, up front, so only components *below* it are left
for the flag to judge — which is the part worth judging.

### Foundation's path resolution goes the wrong way

`URL.resolvingSymlinksInPath()` and `.standardizedFileURL` both turn
`/private/tmp/x` into `/tmp/x` — they *strip* a `/private` prefix rather than
resolving the symlink. That is the opposite of what is needed here, and it
broke two separate things:

- extraction, via the trap above;
- packing, where a source under `/private` never matched its own standardised
  root, so **every member was stored under an absolute path**. The test suite
  missed this entirely, because `FileManager.temporaryDirectory` is
  `/var/folders/...`, which has no `/private` to strip. It showed up the first
  time the CLI was run by hand from a `/private/tmp` scratch directory.

`VPhoneArchivePaths.resolved` uses `realpath(3)` and exists so this decision is
made in one place. **Do not replace it with the Foundation equivalents.**

For the path-containment check, `URL.standardized` is the right one: it
collapses `.` and `..` without touching symlinks, so it does not undo the
`realpath` above.

## `SECURE_NOABSOLUTEPATHS` is deliberately not set

The migration plan asks for all three `SECURE_*` flags unconditionally. Two are
set; this one is not, and the reason is structural rather than a preference.

`archive_write_disk` has no destination-directory concept — it writes relative
to the process's working directory. Reaching an arbitrary destination therefore
means one of:

1. **chdir there.** What tar does, and it was tried. It makes extraction
   process-global and non-reentrant, and it broke immediately under parallel
   tests, leaving files in the repository root.
2. **Give each entry an absolute target.** Then this flag rejects the entry we
   just computed.

So option 2, without the flag, plus an explicit check: each target is
normalised and required to sit under the destination before anything is
written. That is **stronger** than the flag, which only asks whether a stored
path begins with a slash; the check asks where the path actually lands. There
is a test with a hand-built `../escaped` member, checksum and all.

## Known wart

libarchive leaves zero-byte `tar.XXXXXXXX` files in the process's **working
directory** while restoring macOS metadata — a relative `mkstemp` template in
its own sources, which is why `TMPDIR` does not redirect them. Harmless, and
gitignored, but worth knowing that `vphone-archive` running as root during an
install will leave them wherever the installer's cwd is.

## Not yet done

- **Call sites are not switched.** The `$TAR` invocations in `cfw_install*.sh`
  write to a **mounted guest volume** as root, with ownership restored by
  number. Nothing in a unit test covers that, and getting it wrong produces a
  guest that does not boot. It wants a real install and the tree-fingerprint
  comparison from the plan (uid/gid, ACLs, xattrs, hardlink grouping,
  `st_blocks`) before it is switched.
- **`vm export` / `import`** still go through the two-stage tar pipe. The format
  contract there — gnutar, `.tzst` at zstd 3, `.txz` at xz 9 — is expressed in
  `VPhoneArchiveFormat` and `VPhoneArchiveCompression` but not yet wired in,
  and the bidirectional compatibility check (old export read by new import, and
  new export read by `/usr/bin/tar`) has not been run.
