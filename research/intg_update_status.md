# `vphone-intg-update` — progress against the migration plan

> 2026-09-23. Branch off `qof-update-26-fall` @ `6d5ce7d`.
>
> Plan: `~/Desktop/vphone-cli-migration-plan.md`. Its phases are P0 → P4. This
> file is the ledger, because `/TODO.md` is not part of this repo's workflow.
>
> **Recounted against the tree on 2026-09-23**, after P1 and P2 landed. The
> previous revision of this file still said P1 was not started and D1 stood at
> 7.5%; both were stale by several commits. Every number below was measured with
> a command, and the commands are in "How these were counted" at the end so the
> next person can disagree with the measurement rather than the prose.

## Where the four delivery lines stand

| line | plan's completion bar | now |
| --- | --- | --- |
| **D1** Python → zero | hard gate, 100%, achieved at **P2.4** | **6,070 / 6,070 lines — done.** No `.py` tracked, no heredoc, no runtime `python3` |
| **D2** self-contained admission rule | `make check-aux` green | gates 1 and 1b **green**; gate 2 has **38 registered** items (**35** once P2's deletions land) and 0 unregistered; gate 4 does not exist |
| **D3** drop third-party programs | gtar/bsdtar/unzip/zstd/ldid/… | replacements all exist and the `.app` ships **3 binaries and no tools**; the installer shell still resolves `gtar` / `zstd` / `ldid` itself |
| **D4** shell → zero | P3 required, P4 in scope | **0%**, and it grew: **7,173 lines** in 27 files, from 5,895 in 22 (**7,072 in 25** once P2's deletions land) |

D4 going up is not an accounting artifact. `cfw-kit/` (1,036 lines) and
`scripts/check_aux.sh` (327) are both new on this branch; everything else nets
to −85. The 5,098 lines of Python that left `scripts/patchers/` did not take any
shell with them, because the installers called into that Python and now call
into `vphone-cli cfw` instead — same scripts, different callee. `cfw_install*.sh`
is 2,396 lines against 2,410 at the branch base.

## Phase by phase

| phase | scope | state |
| --- | --- | --- |
| S0 | libzstd static in the xcframework? | ✅ **yes**, proven at runtime |
| S2 | liblzma MT encoder? | ✅ **yes**, 4.84x at 1 GiB |
| — | entitlements off `vphone-cli` onto `vphone-vm` | ✅ verified 0 / 7 / 0 / 0 |
| — | AMFI bypass moved out of the project | ✅ docs in 6 languages |
| **P0** | 455 lines of Python | ✅ **complete** |
| P0.5 | `VPhoneArchive` + `vphone-archive` | ✅ library, binary, tests, fingerprint tool |
| P0.5 | switch the archive call sites | ◐ **package side done, shell side not.** `FirmwarePatcher` has no `tar` calls left; `$TAR` in `cfw_install*.sh` and `cfw-kit/lib/common.sh` still finds `gtar` |
| P0.5 | `VPhoneSign`, drop `ldid` | ◐ **bundle clean.** `--use-ldid` (`VPhoneSignLdid.swift:27`) and the shell's own `ldid` lookups remain |
| P0.5 | admission gates 1–3 | ✅ `make check-aux`; gate 1 now passes |
| **P1.0–1.5** | CFW patchers | ✅ **complete** — `scripts/patchers/` deleted at `d90371a`, 26 files / 6,539 lines into 24 `vphone-cli cfw` verbs |
| **P2.0** | can libirecovery see the virtual DFU endpoint? | ✅ **yes** — `research/p2_dfu_spike.md` |
| **P2.1–2.2** | vendor libirecovery + idevicerestore | ✅ `sources/MobileRecoveryCore`, `sources/MobileRestoreCore` |
| **P2.3** | Swift wrapper + call-site replacement | ◐ **built and unit-tested; 4 of the 7 behaviour rows still need a device** |
| **P2.4** | Python → zero | ✅ **complete** — see D1 above |
| P3, P4 | shell | ❌ not started |

`research/p2_restore_off_python.md` records what P2 decided and why, including
the behaviour table row by row.

That AMFI row went round in a circle in one day, so it is worth restating where
it landed. The `amfidont` scripts came out and `vphone-letmein` went in; then
`vphone-letmein` was measured killing amfid outright on a host where
`vm.cs_system_enforcement` reads 1, and came out again. The project ships **no**
bypass: `vphone-cli` probes with `vphone-vm --help`, and on a refusal prints what
to run. `amfidont` is what it names, installed by the user into their own Python.
This costs D1 nothing — it is not a dependency of this repo, and nothing here
imports or invokes it. `research/host_binary_split.md` has the measurement.

## D1, counted

The plan's corrected inventory (§1.2.1 plus the file it missed) is **6,070
lines**: 5,881 standalone across 31 `.py` files at the branch base, plus 189
embedded in shell heredocs. All of it is gone.

| what | lines at `6d5ce7d` | where it went |
| --- | ---: | --- |
| `scripts/patchers/` (26 files) | 5,098 | 24 `vphone-cli cfw` verbs (P1) |
| `scripts/pymobiledevice3_bridge.py` | 268 | `sources/VPhoneRestore` + two C targets (P2) |
| `scripts/fw_manifest.py` | 237 | no callers — deleted |
| `scripts/vm_manifest.py` | 123 | `VPhoneVirtualMachineManifest.swift` |
| `tools/apfs_snap_rename.py` | 95 | `vphone-cli cfw flip-snapshot` |
| `tests/test_dropbear_plist.py` | 60 | died with `cfw_daemons.py` |
| embedded in `fw_prepare.sh` (169) and `cfw_install_{jb,exp}.sh` (20) | 189 | Swift; `fw_prepare.sh` lost 117 lines doing it |

Two corrections to the earlier ledger's arithmetic:

- **`scripts/patchers/` was 5,098 lines at the branch base but 6,539 when it was
  deleted**, still in 26 files. The set churned while the port ran —
  `cfw_patch_hv_vmm_rootfs.py` left, `cfw_records.py` arrived, and
  `cfw_patch_watchdogd.py` roughly doubled. The plan's 5,098 is the right
  denominator for D1 because that is what D1 was scoped against; 6,539 is the
  right number for "how much Python actually had to be ported".
- **The anti-fallback trap is closed.** `_resolve_python3()` is gone from all six
  scripts — the plan's §1.2.3 warning was that deleting the environment would
  make every one of them silently fall back to the system `python3`, and that
  cannot happen now because there is no call site left to fall back.

## D2, counted

`zsh scripts/check_aux.sh --fast`:

- **Gate 1 (dependency closure)** and **gate 1b (relocation)** both report
  nothing. This is the change since the last revision of this file, which
  recorded four failures, all `ldid`: `VPhoneSign` replaced it and the bundle
  stopped shipping it. The `.app` is now exactly `vphone-cli`, `vphone-vm`,
  `vphone-archive`, `signcert.p12` and `AppIcon.icns` — no tools directory, no
  scripts, no interpreter.
- **Gate 2 (source scan)**: 38 registered items, 0 unregistered violations.
  Three of the 38 are Python — the hardcoded `python3` in
  `VPhoneResources.swift` and `setup_machine.sh`'s `python3` / `python3.13`
  lookups — and go out with P2's deletions, leaving 35: 6 `ipsw` and 1 `ldid`
  hardcoded in Swift, and 28 `PATH` lookups in shell (`ldid`, `gtar`, `zstd`,
  `ipsw`, `aea`, `aria2c`, `xcrun`, `shasum`, `sha256sum`, `curl`, `wget`,
  `lsof`).
- **Gate 3** was skipped here (`--fast`). CI must not skip it.
- **Gate 4 — a machine with no Homebrew — still does not exist**, and is still
  the only thing that can support "it works elsewhere". The script says so
  itself. Gates 1–3 are necessary and not sufficient.

`ipsw` and `aea` are deliberately out of scope this round and are not counted
against D3.

## D4, counted

**7,173 lines of tracked `.sh` in 27 files** across `scripts/` and `cfw-kit/`,
against 5,895 in 22 files at `6d5ce7d`. The largest single files:

| file | lines |
| --- | ---: |
| `scripts/cfw_install_exp.sh` | 821 |
| `scripts/setup_machine.sh` | 805 |
| `scripts/fw_prepare.sh` | 589 |
| `scripts/cfw_install.sh` | 579 |
| `scripts/cfw_install_dev.sh` | 512 |
| `scripts/cfw_install_jb.sh` | 484 |
| `scripts/check_aux.sh` | 327 |
| `scripts/vphone_jb_setup.sh` | 312 |
| `cfw-kit/` (5 files) | 1,036 |

P2's deletions take `setup_venv.sh` (49) and `setup_venv_linux.sh` (52) plus the
provisioning blocks inside `setup_tools.sh` and `setup_machine.sh`. Of what is
left, `vphone_jb_setup.sh` (312) runs **inside the guest**, not on the host, so
the host-side figure P3/P4 are actually aimed at is 6,760 — a little less once
those provisioning blocks go.

## Tests

Five test targets, by declaration count: `FirmwarePatcherTests` 341,
`VPhoneCoreTests` 168, `VPhoneRestoreTests` 67, `VPhoneArchiveTests` 39,
`VPhoneSignTests` 32. These are `@Test` / `func test…` declarations, not expanded
parameterized cases, and they are **not** a pass count — the suite was not run in
this pass because another stage held the build directory.

The 14 `FirmwarePatcherTests` failures previously recorded are pre-existing and
unrelated: they need `ipsws/patch_refactor_input/`, which is not in the repo.

`VPhoneRestoreTests` covers everything that runs without a device attached —
argument parsing, the restore-tree rules, the `.shsh` naming, and the C struct
the options turn into. What needs a phone in DFU is not covered, and the target's
stanza in `Package.swift` says so rather than shipping a test that only looks
like one.

## Needs you, and a machine

Nothing below can be done without root or a real guest.

1. ~~**Can `vphone-vm` start a VM holding the entitlements alone?**~~
   **Answered: yes.** A guest booted and libirecovery enumerated its virtual
   DFU endpoint — `research/p2_dfu_spike.md`.
2. ~~**`vphone-letmein` end to end.**~~ **Answered, and the answer removed the
   tool.** With `vm.cs_system_enforcement` = 1 the patched `__TEXT` page gets
   amfid killed (`CODESIGNING`, "Invalid Page") and the guest dies with it.
   Measured twice on macOS 27.0 (26A428) arm64e. What still needs a machine is
   the **replacement instruction path**: that the `amfidont` command
   `vphone-cli` prints on a refusal is correct as printed, on a host with
   nothing installed yet.
3. **The four unverified rows of the P2 behaviour table** — a real restore
   (online and `--offline`), `--no-erase` update-in-place, and the exit-code
   contract on failure. Table and criteria in
   `research/p2_restore_off_python.md`. **Run these on a disposable VM**: a
   failed restore leaves the guest in recovery.
4. **FDR equivalence.** The old bridge ran `Restore(..., ignore_fdr=False)`;
   idevicerestore's FDR handling is internal. Device enumeration cannot settle
   it, so `research/p2_dfu_spike.md` explicitly did not. It shows up only during
   an actual restore, and it must not be assumed away.
5. **Ownership restoration in `VPhoneArchive`**, which only happens as root, so
   `ARCHIVE_EXTRACT_OWNER` has never come into play. This is the blocker on
   switching the `$TAR` calls in `cfw_install*.sh`, which write to a mounted
   guest volume as root — getting ownership wrong there produces a guest that
   will not boot.
6. **Location and TouchID**, which depend on TCC attributing the usage strings
   to `vphone-vm`. It is `CFBundleExecutable`, so it should — worth confirming.
7. **Bridged networking**, now validated at boot instead of at config time.
8. **`cfw flip-snapshot` against a real `Disk.img`.** The byte comparison
   against the Python passed on a synthetic fixture. This is now the only
   implementation — `cfw-kit/run.sh` and `cfw_install_host.sh` both call it.

## Next, in order

1. **Run the four device rows of the P2 table.** Everything else in P2 is
   built and unit-tested; these are what stands between "compiles" and
   "restores". Row 3, `--offline`, is the one the plan's first draft missed
   entirely and the one with four separate criteria.
2. **Finish the archive switch-over.** The host-side temp extractions and the
   IPSW unzip in `fw_prepare.sh` have no ownership problem and can go first.
   The `$TAR` calls in `cfw_install*.sh` wait on item 5 above. Re-run
   `vphone-archive fingerprint <gtar-output> <vphone-output>` after each.

   The comparison the plan asks for has already been run on the real
   `cfw_input.tar.zst` and `cfw_jb_input.tar.zst`: everything matches GNU tar
   except **one directory mtime per archive**, where `vphone-archive` restores
   the archive's recorded value and GNU tar leaves the extraction time.
3. **`vm export` / `import`** onto `VPhoneArchive`, keeping gnutar, `.tzst` at
   zstd 3 and `.txz` at xz 9, checking compatibility both ways.

   Plan §3.9.0-0 says to move these to `VPhoneVM`, which assumed `vphone-cli`
   imports the VM kit. It does not, deliberately, so that move would break
   `vphone-cli vm export`. The right home is `VPhoneArchive`: above
   `VPhoneCore`, and reachable without Virtualization or AppKit.

   It is a real refactor, about twenty call sites in `BundleOpsTests`. Those
   tests already pin the format contract (R11), so whoever does it gets told
   immediately if it is wrong. Worth doing in one go.
4. **P3 — the four `cfw_install*.sh` into one `CFWInstaller`.** This is D4's
   main battle and the only thing that moves that line off 0%. Note that the
   `cfw-kit/` layer added on this branch is 1,036 lines that P3 also has to
   account for; the plan's §P3 was written against a tree where it did not
   exist.
5. **Gate 4** — a machine with no Homebrew.

## Things the plan got wrong

Recorded because they were measured, not reasoned about.

- **`ipsw` / `aea` / `ldid` are called by absolute `/opt/homebrew` path from
  Swift**, not through `PATH`. §1.4 counts the shell call sites. Gate 2 lists
  all of them.
- **`sources/vphone.entitlements` has 7 keys**, not the 4 the plan says or the
  5 `CLAUDE.md` said. Two of them — location and BiometricKit — belong to
  `Devices/`, which is why they all landed on `vphone-vm`.
- **The Python inventory in §1.2.1 misses a file.** It lists five blocks of
  standalone `.py`; `tests/test_dropbear_plist.py` (60 lines) is not among
  them. The total is 6,070, not 6,010.
- **P2 did not need the 73k-line vendoring the plan implies.** §P2.1 reads as
  though the whole libimobiledevice stack had to be carried in tree.
  `AppleMobileDeviceLibrary` ships all five of those libraries plus OpenSSL as
  prebuilt xcframeworks, so only libirecovery (4,629 lines) and idevicerestore
  (20,918, of which 1,399 are ours) are vendored. The argument is in
  `research/p2_restore_off_python.md`.
- **The admission rule caught a bug the plan did not predict**: signing
  `vphone-vm` first sealed the bundle over its siblings in an earlier state,
  and `codesign -v` reported "nested code is modified or invalid". The main
  executable is signed last now, and both build paths verify the seal.
- **D4 was never going to fall out of D1.** The plan treats the Python removal
  as the hard part and the shell as cleanup. Porting 6,539 lines of Python
  changed the shell's line count by −14.

## And one I nearly got wrong

The first measurement of `--no-overwrite-dir` said libarchive already leaves an
existing directory's mode alone, which would have made the flag decorative —
and it was taken from an extraction that was failing partway and applying
nothing. A measurement from a failing code path measures the failure. It is
0700 in, 0777 out when extraction actually works, and the flag matters.

## How these were counted

Re-run these rather than trusting the tables:

```zsh
git ls-files '*.py'                                     # D1: must print nothing
grep -rn '_resolve_python3' scripts/ sources/ Makefile  # must print nothing
grep -rn '<<.*PY' scripts/                              # heredocs: must print nothing
grep -rn 'python' scripts/*.sh                          # comments only, no call sites

zsh scripts/check_aux.sh --fast                         # D2: gates 1, 1b, 2
find .build/vphone-cli.app -type f                      # D2: what the bundle ships

git ls-files scripts cfw-kit | grep '\.sh$' | xargs wc -l   # D4

# The denominators, from the branch base:
git ls-tree -r --name-only 6d5ce7d | grep '\.py$' \
  | while read f; do git show "6d5ce7d:$f" | wc -l; done | awk '{s+=$1} END {print s, NR}'
# The patchers as they stood when deleted:
git ls-tree -r --name-only 'd90371a^' -- scripts/patchers | grep '\.py$' \
  | while read f; do git show "d90371a^:$f" | wc -l; done | awk '{s+=$1} END {print s, NR}'
```
