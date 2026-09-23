# Phase matrix — what each variant installs, and why

Every row of upstream's installers, mapped onto this kit's two variants with the
evidence for the decision. This table is the only auditable form of the claim
"vanilla still boots".

Derived against:

| file | sha256 |
| --- | --- |
| `scripts/cfw_install.sh` | `7d71137763c47e9ac19a1199a97132f0e8990d4c9e8ff0f82e9719cd10e0373b` |
| `scripts/cfw_install_jb.sh` | `5c6c064b2aacce540a4dac15660cb3ec709e07f85d62a0ab49c331a91b062c74` |
| `scripts/cfw_install_host.sh` | `6c84d50b65c37404ca6ab423b6d22b5a69aba27d063da37d7ae0fc682175aa78` |

vphone-cli HEAD `6d5ce7d49b4574859c57c66dff26c5c02bcae6ba`, branch
`qof-update-26-fall`, 2026-09-23. **If any hash has moved, re-diff before
trusting this table.**

Note `cfw_install_jb.sh:43` runs `cfw_install.sh` first, so upstream "jb" means
regular + the JB phases. This kit does not chain; both variants call the same
stage functions in `lib/base_stages.sh` directly.

---

## `cfw_install.sh` (regular, 7 phases)

| upstream | vanilla | jb | why |
| --- | :-: | :-: | --- |
| Cryptex SystemOS + AppOS + dyld symlinks (`:214`) | ✅ | ✅ | the hybrid firmware has a boot chain and no userland without it |
| IOMFB SwapEnd 0x560 — 26.0/18.x (`:331`) | ✅ | ✅ | version-gated; without it the VZ view is black |
| IOMFB force-kern — 27.x (`:336`) | ✅ | ✅ | same, 27's path |
| DSC maxSlide — 27.x (`:364`) | ✅ | ✅ | 27's cache + 512 MiB slide overflows the 6 GiB shared region → dyld cannot map libSystem → **pid 1 panics** |
| lsd embedded-reg — 27.x (`:366`) | ⬜ opt-in | ✅ | upstream `:348-351`: exists so the **`vpregister` first-boot tool** can register JB apps, because 27's `registerApplicationDictionary` is a stub. Nothing walks that path without such a tool. `VANILLA_LSD_EMBEDDED_REG=1` to force. |
| libxpc LWCR self-check — 27.x (`:368`) | ✅ | ✅ | 27's libxpc brk-aborts on the (matched=0, MATCH) pair our signing produces → every entitlement-pinning daemon crash-loops |
| `os_lockdown_mode_enabled` — 27.x (`:370`) | ✅ | ✅ | missing MAC sysctl → launchd abort |
| **2/7** seputil (`:383`) | ✅ | ✅ | SEP rejects the volume without the gigalocker UUID rename |
| diskimagesiod DDI gate — 27.x (`:407`) | ✅ | ✅ | **applied by upstream's regular variant too**, not a JB extra: `waitForDAMount` otherwise hangs forever on the 26.4 hybrid. Version-gated exactly as upstream. |
| gigalocker rename (`:423`) | ✅ | ✅ | part of the same SEP requirement |
| **3/7** AppleParavirtGPU bundle (`:431`) | ✅ | ✅ | backboardd crash loop / black SpringBoard without it. Provenance: `../paravirt-gpu-provenance-kit` |
| **4/7** iosbinpack64 (`:453`) | ❌ | ❌ | this is where bash/dropbear/SSH live. vanilla: explicitly excluded ("不给 ssh"). jb: belongs to the userland slot |
| **5/7** launchd_cache_loader (`:468`) | ❌ | ⬜ slot | **proven dead, not merely unnecessary.** `research/0_binary_patch_comparison.md:183` states its purpose is "Allow modified `launchd.plist`", and `cfw_install.sh:567` (`inject-daemons`) is the **only** writer of that file in the whole installer. Drop 7/7 and the patch has nothing to enable. Re-armed automatically when a slot sets `USERLAND_MODIFIES_LAUNCHD_PLIST=1`. |
| **6/7** mobileactivationd (`:486`) | ✅ | ✅ | otherwise the guest sits on the activation screen forever |
| **7/7** vphoned + 4 daemon plists + `launchd.plist` injection (`:504-569`) | ❌ | ⬜ slot | vphoned is host↔guest control, not a boot requirement. The plists are bash/dropbear/trollvnc/rpcserver_ios — exactly the "什么都不给" list |

## `cfw_install_jb.sh` (JB phases)

| upstream | vanilla | jb | why |
| --- | :-: | :-: | --- |
| **JB-1** launchd jetsam guard (`:244`) | ❌ | ✅ | without it pid 1 panics on boot under the JB kernel patches. Flavour-independent |
| **JB-1** launchdhook `/b` injection (`:237-242`) | ❌ | ⬜ slot | BaseBin-specific → `userland_launchd_hook` |
| **JB-2** iosbinpack64 (`:259`) | ❌ | ❌ | same as 4/7 |
| **JB-3** debugserver entitlements (`:271`) | ❌ | ✅ | flavour-independent, and a debugger is the point of a research JB |
| **JB-3b** Campo mach-lookup, 27 only (`:293`) | ❌ | ✅ | flavour-independent sandbox fix |
| **JB-4** procursus bootstrap (`:317`) | ❌ | ⬜ slot | rootless and roothide disagree on the prefix — this IS the divergence |
| **JB-4** BaseBin → `/cores` (`:378`) | ❌ | ⬜ slot | flavour-specific dylibs |
| **JB-4** TweakLoader (`:411`) | ❌ | ⬜ slot | flavour-specific |
| **JB-5** first-boot setup + `launchd.plist` injection (`:423-471`) | ❌ | ⬜ slot | Sileo/apt/TrollStore finalization; also the thing that makes launchd_cache_loader necessary again |

Legend: ✅ installed · ❌ not installed · ⬜ left to the userland slot or an opt-in flag

---

## Divergences from upstream worth knowing

1. **No chaining.** Upstream jb re-runs the whole regular installer. Here both
   variants call shared stage functions, so the base path cannot drift between
   them — but it also means this kit's jb is *not* byte-identical to upstream's
   jb even before the empty slot is accounted for.

2. **`patch_rootfs_binary` helper.** Upstream open-codes the
   backup → patch → sign → copy → chmod sequence in four places. Same
   semantics, one helper (`lib/common.sh`). diskimagesiod and launchd still
   open-code it because their entitlements must survive the re-sign.

3. **`detect_ios_version` is explicit.** Upstream sets `IOS_VERSION` as a side
   effect of the display-fix block, which makes the stage order silently
   load-bearing. Here it is set once, on purpose, right after the Cryptex lands
   (`SystemVersion.plist` does not exist before that).

4. **Preflight before any write.** Upstream discovers a missing `zstd` or a
   stale `vphone-cli` partway through a streaming install onto a volume with no
   snapshot to roll back to. `preflight()` checks tools, the built binary and
   every `cfw` subcommand the selected variant *and its userland slot* will
   call — each asked of the binary itself with `--help`, which exits 0 only for
   a verb it really has — then refuses with nothing written.

5. **`run.sh` requires `--variant`.** Upstream `cfw_install_host.sh` defaults to
   `exp`. Defaulting to either variant here would hand someone a firmware they
   did not ask for.

6. **`cfw_input/` is kept.** Upstream deletes it for `make` idempotence; opt in
   with `VPHONE_DROP_ARTIFACTS=1`.

## What this table does not tell you

Nothing here was verified by booting a guest. Every ✅ and ❌ is read off
upstream's code and comments plus the research docs. The two rows most likely to
be wrong in practice are the two where this kit *removes* something upstream
always installs — 4/7 and 7/7 — and their failure mode is a guest that boots to
a black screen or a login-less shell you cannot reach, because vanilla
deliberately ships no way in.
