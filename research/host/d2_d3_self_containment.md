# D2 / D3 — the three tiers, and a dist runtime with nothing outside macOS in it

Status as of `a908f81` on `vphone-intg-update`. This is the handover for the
self-containment work: what the rule actually is, what was removed and where
each thing went, what is verified and how, and what is left.

---

## 1. The rule was never one rule

`check_aux.sh` used to hold a single list of "programs we still reach for",
applied to the whole repository. That made `xcrun` in a build script and
`xcrun` in something the `.app` ships count the same, so the list shrinking
said nothing about whether the product was any closer to standing on its own.

Three environments run code here, and they have different rules:

| tier | who runs it | may use |
| --- | --- | --- |
| **build** | the machine that builds the `.app` — a developer's Mac or CI | Xcode, `xcrun`, clang, swift, git, **and Homebrew**. Nothing in this tier ships. |
| **dist** | the shipped `.app`, on a stranger's clean macOS | `/usr/lib`, `/System`, and what is inside the bundle. No Homebrew, no Xcode, **no `PATH` lookup at all**. |
| **guest** | inside the VM | out of host self-containment scope. These ship as payload to be copied in, never run on the host. |

Every script declares its tier on **line 2**:

```sh
#!/bin/zsh
# vphone-tier: dist
```

`scripts/dist_manifest.sh` reads those declarations and prints the dist
payload. `scripts/build.sh` and `make bundle` both stage from it, so the
bundler is an **allowlist**. It used to be a list of exclusions, which is how
the `.app` came to carry `build.sh`, `check_aux.sh` and `setup_tools.sh` — the
last of which runs `brew install`. An undeclared script now ships nowhere and
gate 0 says so.

> `make bundle` stages `Contents/Resources` now. It did not, and `build.sh`
> did, so `make check-aux` was inspecting a five-binary bundle while users got
> twenty scripts and a Homebrew-linked `trustcache`. **The gate was green
> because it was looking at the wrong artifact.** If you add a bundling step,
> add it to both or the gate goes blind again.

---

## 2. What the dist tier reached for, and where each one went

| was | now | checked by |
| --- | --- | --- |
| `xcrun` (five iOS binaries cross-compiled at CFW-install time) | `scripts/guest_binaries.mk` builds them at build time; they ship in `Contents/Resources/guest` | gate 2, and a byte comparison against the old invocations |
| `ldid` | `vphone-cli sign` / `dump-entitlements` | same CodeDirectory and CDHash as `ldid` on the real `vphoned`; gate 3 signs with `env -i PATH=/usr/bin:/bin` |
| `gtar`, `zstd`, `tar` | `vphone-archive` (`extract`, `create`, `decompress`) | gate 3 round-trips a `.tzst` with no `zstd` on `PATH` |
| `ipsw fw aea --key` | `vphone-cli fw aea-key` | byte-identical to `ipsw` on a real 24A435 archive |
| `ipsw img4 im4p create/extract` | `vphone-cli fw im4p-create` / `im4p-extract`, and `IM4P` directly in `CryptexFilesystemPatcherSealing` | byte-identical containers for `isys`/`trst`/`msys`; gate 3 round-trips one |
| `ipsw download ipsw --urls` | `vphone-cli fw urls` | same 31 URLs for `iPhone17,3`, diffed against `ipsw` |
| `ipsw download appledb` + partial zip extract | `vphone-cli fw seal-tool` over `VPhoneRemoteZip` | pulls `apfs_sealvolume` out of an 18 GB remote IPSW in ~7 s |
| `aria2c`, `wget` | deleted; `/usr/bin/curl` resumes with `-C -` | gate 2 |
| `trustcache` (bundled, linked `/opt/homebrew`'s `libcrypto.3`) | **deleted** — nothing ever invoked it; the trust cache comes from `cryptexctl` in `/System/Library/SecurityResearch` | gate 1 |

`DIST_REMAINING` in `check_aux.sh` — the list a release requires to be empty —
**is empty**. Keep it that way; adding a line is a decision to ship something
that does not work on a clean Mac.

### The compile/install split

Five Mach-Os run inside the guest: `vphoned`, `TweakLoader.dylib`,
`vpregister`, `libvcamcaptured.dylib`, `libcamfix.dylib`. Every one used to be
compiled at CFW-install time — three by the installers, and `vphoned` twice
more (again by `FirmwarePatcher.buildVphoned`). That made a full Xcode install
a prerequisite for putting firmware on a VM.

**Compiling moved to build time. Signing did not, and cannot**: it uses the
target VM's own `cfw_input/signcert.p12`, which does not exist until a VM does.
`cfw install` still runs in dist, as it must — it is something `vphone-cli`
does on the user's machine.

`scripts/guest_binaries.mk` keeps the installers' own argument order,
framework list included. That looks arbitrary and is load-bearing:
`-framework` order decides `LC_LOAD_DYLIB` order, which decides the indirect
symbol table's numbering. With it, `vpregister` and `libvcamcaptured.dylib`
come out **byte-identical** to what the installers used to produce.
`TweakLoader.dylib` differs in exactly two fields per slice — `LC_UUID`
(content-derived, differs between any two links) and `LC_ID_DYLIB` (it takes no
`-install_name`, so this defaults to the output path; nothing reads it, the
guest loads the file by absolute path from `/var/jb/usr/lib`).

---

## 3. Reading files: map, don't slurp

This bit cost a machine, so it is worth stating plainly.

`Data(contentsOf:)` with no options reads the whole file into resident memory.
Fine for a plist; ruinous for what this project opens:

* `DSCLocalSymbolTable` parsed `dyld_shared_cache_arm64e.symbols`, **1.17 GB**
  on iOS 27, reading its string table and nlist array whole.
* `DSCChunkSet.findStringVMAs` read each executable mapping whole — ~130 MB
  each, two dozen of them — so one full-cache string search was **3.3 GB** of
  `Malloc Large`.
* `ManifestHashPatcher` hashes every component the build identity names, and
  that list includes `OS`: a **ten gigabyte** filesystem image.

All three map now. Measured on `DSCFlatAddressingTests`, footprint went
**3419 MB → 13 MB**. RSS is still ~1.1 GB and that is the point: it is clean
file-backed pages the kernel reclaims for free, not dirty heap it has to swap.

Two details that are easy to get wrong:

1. **Do not slice a mapping and hand it to `loadLE(_:at:)`.** That helper
   passes its offset to `Data.copyBytes(to:from:)`, whose range is in the
   collection's index space — correct only where `startIndex` is zero, which a
   slice of a mapping never is. `DSCLocalSymbolTable` holds one mapping and
   *offsets into it* for this reason.

2. **Never map a buffer you will mutate and write back over its own file.**
   `Data.write(to:)` replaces the file the buffer is mapped from; the mapping
   is invalidated underneath the write that is reading through it, and the next
   page fault is a **SIGBUS** — a killed process, no failed assertion, nothing
   in the log. Those reads say so in the spelling:
   `Data(contentsOfFileToRewrite:)`, defined once in
   `Sources/FirmwarePatcher/Binary/InPlaceRewrite.swift`.
   `VPhoneSigner` keeps its mapping and is safe *because* it renames over the
   file rather than truncating it; rename does not invalidate a mapping.

`make check-aux` enforces the rule for `Sources/`. **`Tests/` is deliberately
outside it**: a test opens a committed fixture of a few megabytes, so mapping
buys nothing, and those fixtures are exactly what the patch tests mutate and
write back over. Holding the tests to the production rule would trade a memory
problem they do not have for a SIGBUS they would.

---

## 4. The gates

`make check-aux`. None of them proves self-containment alone.

| gate | what it does |
| --- | --- |
| 0 | every script declares a tier on line 2 |
| 1 | recursive `otool -L` over the bundle; every absolute path fails, including one that resolves inside the bundle today |
| 1b | the same, on a copy moved elsewhere and renamed |
| 1c | the bundle holds the dist manifest and **nothing else** — a build-tier file inside it is a hard failure, and so is a stale file the manifest does not name |
| 2 | per-tier source scan: `PATH` lookups, Homebrew paths, dist scripts exec'ing build-tier scripts, unmapped reads in `Sources/`, and any interpreter anywhere |
| 3 | each entry binary doing its smallest real job under `env -i PATH=/usr/bin:/bin` |

**Gate 4 is still missing**: a machine with no Homebrew at all, running a
matrix of real work. Gate 3 clears the environment but `/opt/homebrew` is still
on disk, so it cannot see a hardcoded absolute path. Do not read a green run
here as "it will work elsewhere".

---

## 5. Verified

Against the real tools, not by inspection:

* `fw urls --device iPhone17,3` — identical 31 URLs to `ipsw download ipsw --urls`.
* `fw aea-key` — byte-identical to `ipsw fw aea --key`, and it decrypted both
  24A435 volumes (the 8.8 GB rootfs and the 2.3 GB SystemOS cryptex) with
  `/usr/bin/aea`.
* `fw im4p-create` — byte-identical containers for `isys`/`0`, `trst`/`1`,
  `msys`/`0`; `im4p-extract` round-trips to the original payload.
* `fw seal-tool --version 26.1` — a working arm64e `apfs_sealvolume` out of an
  18 GB remote macOS IPSW, in 7.4 s, from a **relocated** bundle under
  `env -i PATH=/usr/bin:/bin`.
* `fw_prepare.sh --list` — the full firmware matrix, same conditions.
* `vphone-cli sign` — same CodeDirectory, same CDHash as `ldid` on the real
  `vphoned`. (The CMS blob differs; it always has. The cdhash is what AMFI
  checks.)
* All gates green, `DIST_REMAINING` empty.
* **641 tests in 113 suites, zero issues, exit 0.**

### Not verified

**A CFW install has not been run end to end since this change.** It needs root
and a powered-off VM. The pieces it touches were each checked in isolation, but
the flow — `cfw install --variant jb` staging the five prebuilt guest binaries,
signing them with `vphone-cli sign`, unpacking the bootstrap with
`vphone-archive` — has not been driven once. **That is the first thing to do.**

---

## 6. Test fixtures — where they came from

`ipsws/` is gitignored; the fixtures are large and must be rebuilt locally.

* `ipsws/ref_extract/macho_pristine/` and `ref_extract/dsc_pristine/` came out
  of `iPhone17,3_27.0_24A435_Restore.ipsw`: the six Mach-Os from the rootfs
  (`043-69462-653.dmg.aea`), the 6.7 GB shared cache from the SystemOS cryptex
  (`043-70113-702.dmg.aea`). Both decrypted with `vphone-cli fw aea-key` plus
  `/usr/bin/aea`.
  **24A435 is the right build and that is checkable**: `watchdogd` hashes to
  `0309b868…` and `mobileactivationd` to `89233513…`, which are the digests
  frozen in `DSCHVVMMPatcherTests`. If those do not match, the fixture is from
  the wrong firmware and nothing below it is a comparison.
* `ipsws/patch_refactor_input/raw_payloads/` was extracted from a prepared
  26.1/23B85 restore tree with `vphone-cli fw im4p-extract`.
* `ipsws/patch_refactor_input/reference_patches/` **cannot be regenerated.** It
  is the output of the deleted Python patchers. `PatchComparisonTests` skips
  when it is absent, with that written into the file. What still guards those
  patchers is the frozen-digest work in the same directory, which carries its
  reference values in the source rather than in a file nobody has.

---

## 7. Left open

* **`cfw-kit` is build tier**, declared in writing in `cfw-kit/run.sh` with the
  reason: it still reaches for `ldid`/`gtar`/`zstd`/`ipsw` the way
  `scripts/cfw_install*.sh` did before they were cleaned out, so it does not
  ship and a dist user cannot run it. Whether it gets the same treatment or
  stays a development tool is a P3 question, left open on purpose. **Do not add
  it to `dist_manifest.sh` until it is cleaned.**
* **D4 — the host-side shell.** The dist tier is still ten `.sh` files. Turning
  them into Swift is the next line of work and is deliberately not started
  here; the tiers and the gates are what make it possible to do it one script
  at a time without losing track of what ships.
* **Gate 4**, above.
* `git-lfs` is the one Homebrew formula left in `setup_machine.sh`, and it is
  not a tool this project runs — it is what `git clone` needs for
  `scripts/resources`.
