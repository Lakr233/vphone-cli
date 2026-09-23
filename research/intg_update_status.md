# `vphone-intg-update` — progress against the migration plan

> 2026-09-23. Branch off `qof-update-26-fall` @ `6d5ce7d`.
>
> Plan: `~/Desktop/vphone-cli-migration-plan.md`. Its phases are P0 → P4; the
> approved execution order for this branch (`~/.claude/plans/mellow-weaving-gem.md`)
> covered **P0 and part of P0.5 only**, and said so up front. This file is the
> ledger, because `/TODO.md` is not part of this repo's workflow.

## Where the four delivery lines stand

| line | plan's completion bar | now |
| --- | --- | --- |
| **D1** Python → zero | hard gate, 100%, achieved at **P2.4** | **455 / 6,070 lines (7.5%)** — P0 only |
| **D2** self-contained admission rule | `make check-aux` green | gates 1–3 exist and run; **4 failures**, all `ldid` |
| **D3** drop third-party programs | gtar/bsdtar/unzip/zstd/ldid/… | archive four **replaced but not switched over**; `ldid` still shipped |
| **D4** shell → zero | P3 required, P4 in scope | **0%** — 7,304 lines host-side |

## Phase by phase

| phase | scope | state |
| --- | --- | --- |
| S0 | libzstd static in the xcframework? | ✅ **yes**, proven at runtime |
| S2 | liblzma MT encoder? | ✅ **yes**, 4.84x at 1 GiB |
| — | entitlements off `vphone-cli` onto `vphone-vm` | ✅ verified 0 / 7 / 0 / 0 |
| — | AMFI bypass moved out of the project | ✅ docs in 6 languages |
| **P0** | 455 lines of Python | ✅ **complete** — all three gone from the tree |
| P0.5 | `VPhoneArchive` + `vphone-archive` | ✅ library, binary, tests, fingerprint tool |
| P0.5 | switch the archive call sites | ❌ **nothing calls it yet** |
| P0.5 | `VPhoneSign`, drop `ldid` | ❌ not started |
| P0.5 | admission gates 1–3 | ✅ `make check-aux`, fails on `ldid` by design |
| P1.0–1.5 | CFW patchers, **5,098 lines** | ❌ not started |
| P2.0–2.4 | restore, 268 lines + venv removal | ❌ not started |
| P3, P4 | shell | ❌ not started |

That AMFI row went round in a circle in one day, so it is worth stating where
it landed. The `amfidont` scripts came out and `vphone-letmein` went in; then
`vphone-letmein` was measured killing amfid outright on a host where
`vm.cs_system_enforcement` reads 1, and came out again. The project now ships
**no** bypass at all: `vphone-cli` probes with `vphone-vm --help`, and on a
refusal prints what to run. `amfidont` is what it names, installed by the user
with `xcrun python3 -m pip install --user amfidont`. This costs D1 nothing —
it is not a dependency of this repo, nothing here imports or invokes it, and
`scripts/pymobiledevice3_bridge.py` remains the only Python program in the
tree. `research/host_binary_split.md` has the measurement and the reasoning.

Tests: `VPhoneCoreTests` 152/152, `VPhoneArchiveTests` 15/15. The 14
`FirmwarePatcherTests` failures are pre-existing — they need
`ipsws/patch_refactor_input/`, which is not in the repo.

## What is left, counted

**Python — 5,426 lines in 28 files, plus 189 embedded in shell**

| what | lines | phase |
| --- | ---: | --- |
| `scripts/patchers/*.py` (26 files) | 5,098 | P1 |
| `scripts/pymobiledevice3_bridge.py` | 268 | P2 |
| `tests/test_dropbear_plist.py` | 60 | P1.5 |
| embedded in `fw_prepare.sh`, `cfw_install_{jb,exp}.sh` | 189 | P1.4 / P2.4 |

`tests/test_dropbear_plist.py` is worth knowing about separately: it passes, it
covers live code (`patchers/cfw_daemons.py`), and **no runner invokes it** — no
Makefile target, no CI. The other two files in `tests/` have Makefile targets.
It dies with P1.5 either way, so wiring it up is optional, but right now it is
coverage nobody is collecting.

**The `_resolve_python3()` fallback is untouched in all six scripts**
(`cfw_install{,_dev,_jb,_exp}.sh`, `patch_{camera,hv_vmm}_userland.sh`). Each
ends in `command -v python3`, so deleting the venv makes everything **silently
fall back to system Python**. Plan §1.2.3 calls this D1's main trap, and it is
why D1's acceptance has to run on a PATH with no `python3` at all.

**Shell — 7,304 lines host-side**, of which `cfw_install*.sh` is 2,410 and
`setup_machine.sh` + `fw_prepare.sh` another 1,522.

## Dead code removed (this pass)

- `scripts/fw_manifest.py` (251) and `tools/apfs_snap_rename.py` (108) —
  both had no callers left. `tools/` is gone with it. Recover either from git
  if a comparison is ever needed again: `git show f637f63:tools/apfs_snap_rename.py`.
- `scripts/build.sh` — stopped creating the now-empty `Resources/tools`, and
  the bundled-assets line no longer claims to ship it. The `rm -rf` stays, with
  a note: the bundle is built over whatever is already there, so an older one
  still has the empty directory to clear.
- `cfw-kit/run.sh` — **this one was a live break, not dead code.** Deleting
  `apfs_snap_rename.py` broke `run.sh:156`, which still called it by path. The
  first sweep missed it by only searching `scripts/`, `Makefile` and `sources/`.
  It is now `vphone-cli cfw flip-snapshot`, using the same resolution order as
  `scripts/cfw_install_host.sh`, and `$PY` is gone with its only use. **Any
  future file deletion has to be swept against `cfw-kit/` too.**
- `AGENTS.md` — the tree listed `tools/apfs_snap_rename.py` as "used by
  `cfw_install_host.sh`", which stopped being true before this pass. It also
  had no entry for `VPhoneCore`, `VPhoneArchive`, `FirmwarePatcher`,
  `vphone-archive` or `cfw-kit`, and still said "three host binaries".

Swept and found clean: no unreferenced Swift type in `VPhoneCore`,
`VPhoneArchive` or `vphone-cli`; every repo-relative path literal in shell,
Swift, C and the Makefile resolves; every `requirements.txt` entry is still
imported except `setuptools`, which is a build dependency of `keystone-engine`
and must stay.

## Needs you, and a machine

Nothing below could be done without root or a real guest.

1. ~~**Can `vphone-vm` start a VM holding the entitlements alone?**~~
   **Answered: yes.** A guest booted and libirecovery enumerated its virtual
   DFU endpoint — `research/p2_dfu_spike.md`. Everything rested on this.
2. ~~**`vphone-letmein` end to end.**~~ **Answered, and the answer removed the
   tool.** It works only where the kernel does not enforce code signing; with
   `vm.cs_system_enforcement` = 1 the patched `__TEXT` page gets amfid killed
   (`CODESIGNING`, "Invalid Page") and the guest dies with it. Measured twice
   on macOS 27.0 (26A428) arm64e. What still needs a machine is the
   **replacement instruction path**: that the `amfidont` command `vphone-cli`
   prints on a refusal is correct as printed on a host with nothing installed
   yet.
3. **Location and TouchID**, which depend on TCC attributing the usage strings
   to `vphone-vm`. It is `CFBundleExecutable`, so it should — worth confirming.
4. **Bridged networking**, now validated at boot instead of at config time.
5. **`cfw flip-snapshot` against a real `Disk.img`.** The byte comparison
   against the Python passed on a synthetic fixture. This is now the only
   implementation — `cfw-kit/run.sh` and `cfw_install_host.sh` both call it.

## Next, in order

1. **Switch the archive call sites.** `vphone-archive` is built, bundled and
   tested, and nothing calls it yet.

   The comparison the plan asks for has been run on the real
   `cfw_input.tar.zst` and `cfw_jb_input.tar.zst`: everything matches GNU tar
   except **one directory mtime per archive**, where `vphone-archive` restores
   the archive's recorded value and GNU tar leaves the extraction time.

   Still untested is **ownership restoration**, which only happens as root, so
   `ARCHIVE_EXTRACT_OWNER` never came into play. Close that before switching
   the `$TAR` calls in `cfw_install*.sh`, which write to a mounted guest volume
   as root — getting ownership wrong there produces a guest that will not boot.
   The IPSW unzip in `fw_prepare.sh` and the host-side temp extractions have
   neither problem and can go first. Re-run with
   `vphone-archive fingerprint <gtar-output> <vphone-output>`.
2. **`VPhoneSign`** — the only thing that clears the four remaining admission
   gate failures, all of them `ldid`. Plan §3.11 has the measurements. The
   `signcert.p12` needs re-wrapping with a password first, and the old
   empty-password copy has to stay for the `--use-ldid` escape hatch.
3. **`vm export` / `import`** onto `VPhoneArchive`, keeping gnutar, `.tzst` at
   zstd 3 and `.txz` at xz 9, checking compatibility both ways.

   Plan §3.9.0-0 says to move these to `VPhoneVM`, which assumed `vphone-cli`
   imports the VM kit. It does not, deliberately, so that move would break
   `vphone-cli vm export`. The right home is `VPhoneArchive`: above
   `VPhoneCore`, and reachable without Virtualization or AppKit.

   It is a real refactor, about twenty call sites in `BundleOpsTests`. Those
   tests already pin the format contract (R11), so whoever does it gets told
   immediately if it is wrong. Worth doing in one go.
4. **Gate 4** — a machine with no Homebrew. Still the only thing that can
   support "it works elsewhere"; gates 1–3 are necessary and not sufficient,
   which the script says out loud.

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
- **The admission rule caught a bug the plan did not predict**: signing
  `vphone-vm` first sealed the bundle over its siblings in an earlier state,
  and `codesign -v` reported "nested code is modified or invalid". The main
  executable is signed last now, and both build paths verify the seal.

## And one I nearly got wrong

The first measurement of `--no-overwrite-dir` said libarchive already leaves an
existing directory's mode alone, which would have made the flag decorative —
and it was taken from an extraction that was failing partway and applying
nothing. A measurement from a failing code path measures the failure. It is
0700 in, 0777 out when extraction actually works, and the flag matters.
