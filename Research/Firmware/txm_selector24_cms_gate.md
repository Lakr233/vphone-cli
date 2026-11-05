# TXM selector 24 CMS gate — the iPhone 17,3 / 27.0.1 (24A446) first-boot panic

> Historical investigation. The forced type-10 pre-check patch described below
> has been removed in favor of [native signature classification](txm_executable_remap.md).
> Host tests cover the original rejection paths; the replacement has iOS 27.1
> remap results and tester-reported startup success. The boot results below
> apply to the former implementation, not a retest of the same 27.0.1 pairing.

Investigated 2026-10-04, after a `vm create` that defaulted to
`iPhone17,3 27.0.1 (24A446)` restored and CFW-installed cleanly, then panicked
on first boot:

```
TXM [Error]: CodeSignature: selector: 24 | 0x91 | 0x24 | 1
panic: unexpected SIGKILL of init with reason -- namespace 9 code 0x1
```

The VM (`unlocktest-iphone`) was deleted before this analysis; everything
below was rebuilt statically from the IPSWs themselves (members fetched by
HTTP range from the CDN zips; artifacts kept under `/tmp/txm-*.bin`).

## Which TXM actually boots

`mergeCloudOS` (`VPhoneFirmwarePreparer.swift`) copies cloudOS
`Firmware/*.im4p` into the iPhone restore tree **with overwrite**, so
`txm.iphoneos.research.im4p` from cloudOS `26.4-23E5207q`
(**`TrustedExecutionMonitor_Guarded-187.100.3`**, 442400 bytes) replaces the
iPhone IPSW's own before the patcher and restore ever see it:

| Source | TXM build | Size |
| --- | --- | --- |
| cloudOS `26.4-23E5207q` (**what boots**) | 187.100.3 | 442400 |
| iPhone `26.6.2_23G90` (silently discarded since PR #486) | 187.120.2 | 442400 |
| iPhone `27.0_24A435` / `27.0.1_24A446` (silently discarded) | 217.0.2 | 557088 |

Through 26.x the two sides shipped near-identical TXMs, so the override was
invisible and harmless. iOS 27 moved the TXM a full version (+115 KB) while
the VM kept booting the 26.4-era 187.100.3. The 12 dev patches apply to (and
were verified against) 187.100.3. The VM's SPTM is also cloudOS's
(`sptm.vresearch1.release.im4p`); the iPhone IPSW only ships `sptm.t8140`
for its own hardware. TXM and SPTM in the guest are a matched 26.4 pair.

Offsets below are raw file offsets, given for **187.100.3** (what boots)
with 217.0.2 in parentheses where useful. 187.100.3 `__TEXT_EXEC`: file
offset `0x1c000`; 217.0.2: file offset `0x2c000`, vmaddr
`0xfffffff017030000` (neither is the 26.3 layout in `txm_jb_patches.md`).

## Decoding the panic value

The kernel-side log prints the selector number followed by the low, middle
and high bytes of TXM's 32-bit error return. `0x91 | 0x24 | 1` is
**0x0001_2491**.

## The selector-24 ladder (identical shape in both TXM versions)

### `sub_31F74` (217.0.2: `sub_43CB8`) — multi-step validator

```asm
0x31f94:  str  wzr, [sp, #0xc]          ; flags = 0
0x31fb4:  ldp  x0, x1, [x20, #0x30]     ; ctx->blob30, size
0x31fbc:  bl   0x2fc54                  ; read BE u32 at blob+0xC → flags
0x31fc8:  bl   0x30bac                  ; policy pre-check walk
0x31fd0:  b.eq 0x32000                  ; pre-check PASSED → return 2 (accept)
0x31fd8:  ldrb w8, [x8, #0xd0]          ; table flag
0x31fdc:  tbz  w8, #0, 0x32020          ; clear → fall to ladder
          ...                           ; set → tolerated (marks type 0xa/5)
0x32020:  ldrb w8, [sp, #0xc]
0x32024:  tbnz w8, #1, 0x32040          ; flags bit1 (CS_ADHOC) → sub_30B1C
0x32030:  bl   0x30774                  ; ← CMS full verification (this panic)
0x32048:  bl   0x30b1c                  ; ad-hoc / alternate path
0x3205c:  bl   0x30a78                  ; third fallback
```

The pre-check walk (`sub_30BAC`) is the 217/187 equivalent of the 26.x
pre-check chain (library validation, runtime flag, jit entitlement, team
id, SRD, extended research, hash type). The patched `check_hash_flags`
(187.100.3: near `0x31a84`, early-returned PASS by
`txm-boot-selector24_bypass`) is one step inside it.

### `sub_30774` (217.0.2: `sub_424A8`) — the CMS gate that fired

```asm
0x307e8:  mov  w25, #0xb01
0x307ec:  movk w25, #0xfade, lsl #16    ; CSMAGIC_BLOBWRAPPER
0x307f0:  mov  w21, #0x2491
0x307f4:  movk w21, #1, lsl #16         ; w21 = 0x12491 (step error)
0x307f8:  ldp  x0, x1, [x20, #0x30]     ; blob30, size
0x30804:  bl   0x301a8                  ; parse one byte → sp+7
0x30808:  ldp  x0, x1, [x20, #0x18]     ; signature buffer, size
0x30810:  mov  w2, #0x10000             ; limit
0x30814:  mov  w3, #0xfade0b01          ; magic
0x30820:  bl   0x2ecb8                  ; find_blob(buf, size, limit, magic, 0)
0x30824:  cbz  x0, 0x30860              ; NOT FOUND →
0x30860:  mov  w8, #0x124               ;   exit code 0x124 → returns 0x12491
```

If the wrapper *is* found, the function locates the CodeDirectory
(`0xfade0c02`, searched as `magic + 0x101`), parses both, and verifies the
manifest cdhash (≤0x40-byte hash at `ctx+0x40`) — the full "the CMS says who
signed this" step. The exit packs the printed error:
`mid=(w8&0xff)<<8` (0x24), `low=w21&0xff` (0x91), `high=w22` (0x10000 → 1).

**0x12491 means: no `CSMAGIC_BLOBWRAPPER` blob in the signature data that
selector 24 was handed.**

## Why our launchd dies there

`patchMachO` re-signs `/sbin/launchd` (jetsam guard patch + `/vh` injection,
`system-launchd-boot-jetsam_panic_guard_bypass`) with `VPhoneSigner` at its
default `style: .ldid`:

```swift
case ldid:
    // "there is no CMS blob and the ad-hoc flag is not set"
case appleAdHoc:
    signature.flags = 0x2 // kSecCodeSignatureAdhoc
    signature.cmsReservation = 0
```

(`VPhoneSign/Signing/VPhoneSigner.swift`.) So the re-signed launchd carries
**no CMS wrapper and CodeDirectory flags = 0**: flags bit1 is clear (the
ad-hoc branch is not taken), and the CMS branch finds no `0xfade0b01`
anywhere → 0x12491 → init SIGKILLed. None of the 12 applied TXM patches
touches this ladder — hence a clean patch log with no warnings.

## What is and is not the trigger (elimination, 2026-10-04)

The failing machine ran iPhone-class iOS 27.0.1 with local bundle
`2.4.0-local.ed71da3b` (installed 2026-10-04 00:26, mid audio-branch WIP).
Every candidate signed artifact in the boot path was then compared between
the failing and passing combinations:

| Artifact | Check | Result |
| --- | --- | --- |
| TXM | sha256, 24A435 vs 24A446 IPSW | identical (and both overridden by cloudOS 187.100.3 anyway) |
| `/sbin/launchd` | extracted from both rootfs (AEA-decrypted), `cmp` + entitlements + `codesign -dv` | **byte-identical**, both Apple ad-hoc (`flags=0x2`, no team, CD v0x20400, 150+9 hashes) |
| dyld shared cache | chunk CD flags/version/slot layout, 435 vs 446 | identical shape: CD v0x20400 `flags=0x2`, slots {CD, empty requirements, empty CMS}; 27.0.1 is a minimal update (a few chunks shift by ~16 KB) |
| DSC patching | all nine verbs on both caches | identical site counts (29 cstrings, 31 forced, maxSlide overflow→0, 2/2 camera, …), re-attest clean |
| `/vh` launchdhook dylib | `codesign -dv --verify` in ed71da3b vs 2.5.0 | structurally valid, adhoc `flags=0x2`, same CD shape |

Known boots, for contrast:

| Guest | iOS | Bundle | Result |
| --- | --- | --- | --- |
| iPhone-class (D47) | 27.0 (24A435) | audio-branch local, 2026-10-04 ~15:00 (commit `c812baf` measurement) | boots |
| iPad16,1 | 27.0.1 (24A446) | 2.5.0 (2026-10-04) | boots |
| iPhone17,3 | 27.0 | PR #486 (2026-09-24, pre-migration Python pipeline) | boots |
| iPhone-class | 27.0.1 | `2.4.0-local.ed71da3b` (2026-10-04 00:26) | **0x12491 panic** |

Note the launchd result kills the earlier "27.0.1 launchd data trips a
policy" theory: the binary the gate rejected — if it was launchd at all — is
byte-for-byte what boots on 27.0. Whatever flipped the `sub_30BAC` pre-check
into the CMS fallback is either (a) something in that WIP bundle's install
output (the audio branch was mid-refactor at 00:26; today's bundles carry the
fixes from `8fa502a`/`fa50d48`/`62ee326` and boot), or (b) a 27.0.1
system-volume input outside launchd/cache/DSC (restore ramdisk, Preboot
content), or (c) TXM runtime policy state that boot handed it differently.
The one discriminating experiment: **iPhone 17,3 + 27.0.1 + current bundle** —
`vphone-launchpad-cli vm create t271 --iphone-source ~/.vphone/ipsws/iPhone17_3_27.0.1_24A446_Restore-1c2c1e8da8de.ipsw`
(IPSW already cached). Boots ⇒ the WIP bundle was the trigger; panics
identically ⇒ 27.0.1-specific input, pursue the fixes below.

## Confirming the remaining link (reveal procedure)

1. Download `043-70113-711.dmg.aea` (24A446 rootfs) and `043-70113-702.dmg.aea`
   (24A435) from the two iPhone IPSWs (zip members; the rest of the 12 GB is
   not needed).
2. `vphone-cli fw aea-key <dmg.aea>` → `aea decrypt -key-value …` (documented
   flow; it worked on both 24A435 volumes before).
3. Attach the decrypted APFS images, pull `sbin/launchd` from each (and from
   the iPad 16,1 27.0.1 IPSW as the passing 27.0.1 control).
4. Compare, in order of likelihood: embedded entitlements (plist and DER
   slots), CodeDirectory version/hashType/flags/identifier, superblob slot
   list (magics and order).
5. Reproduce by re-running the CFW launchd staging on all three and diffing
   `VPhoneSigner` output.

## Round 3 (2026-10-04 evening): every input-side artifact is now identical

The `0x32202` boot was compared against patchtest-iphone (iPhone-class, iOS
27.0, boots, driven by the parallel session) artifact by artifact:

| Artifact | t271 (27.0.1, dies) | patchtest (27.0, boots) |
| --- | --- | --- |
| console, boot start → ignition | same APFS/root-snapshot/root-hash-auth lines on both (benign) | same |
| magazine/nonce errors | present (`pdmg/d1ma/c1ge/…` errno 2, and `cptx/c1bt` 13/6 on earlier boots — the tag set varies *between boots of the same machine*) | present (`cptx` 13, `c1bt` 6) — noisy, not the discriminator |
| installed devicetree.img4 (Preboot) | parsed both DTBs (Apple flattened format: LE u32 counts, LE u32 length with bit 31 as a syscfg flag): **605/605 properties identical** | identical |
| on-disk re-signed launchd | flags=0x2 → dies 0x32202; flags=0 → died 0x12491 | **flags=0x0 (ldid shape) and passes the pre-check — no selector-24 line at all** |
| trust cache files on disk | none found on System/Preboot/Cryptexes of either machine — the volume trust caches are personalized into the boot chain at restore time (the `magazine`/nonce path), not stored as files | none either |

The signature shape is therefore **not** what the pre-check keys on (a
flags=0 ldid launchd passes on 27.0; both shapes die on 27.0.1). With
launchd, device tree, dyld cache, TXM, kernel, SEP and SPTM all eliminated,
what remains is per-build data the restore personalizes into the guest's
trust chain — the **trust cache content itself** (27.0.1's TCTF/magazine
format or its personalization metadata vs what the fixed 26.4 kernel/TXM
can admit). Where to go next:

1. Ask the restore side where trust caches land: `VPhoneRestore` /
   idevicerestore personalize `*.dmg.trustcache` — trace what it writes and
   what the 26.4 kernel expects to find at boot.
2. Reverse the three policy callbacks behind `sub_30BAC`'s walk in TXM
   187.100.3 (selector `0x7e51`, table slots `+0x20/+0x18`) — the definitive
   answer to which input flips.
3. Empirical discriminator: boot 27.0.1 with an *unpatched* Apple launchd
   (swap `sbin/launchd.bak` back in through the CFW mount). If the original
   — whose cdhash is in Apple's cache — also dies, the trust caches never
   load at all on 27.0.1 and the ladder is unreachable for everyone; if it
   boots, the caches load and the policies specifically reject re-signed
   hashes on 27.0.1.

## Round 4 (2026-10-04 night): the definitive experiment — it is not the signing

`system-launchd-boot-jetsam_panic_guard_bypass` was blocked through
`PatchSelection.plist` (`BlockedPatches`, honored by `fw patch` with a
boot-essential warning), the tree re-prepared and CFW re-installed, so the
guest booted the **pristine Apple launchd** — ad-hoc flags=0x2 straight from
the IPSW, its cdhash in Apple's static trust cache, no `/vh` injection, no
re-signing at all.

**It died identically**: `TXM [Error]: CodeSignature: selector: 24 | 0x02 |
0x22 | 3` (0x32202) → `unexpected SIGKILL of init`.

That closes the case at this level:

- The re-signed binaries were never the problem. On the iPhone17,3 27.0.1
  guest, **TXM's selector-24 admission rejects every binary — including
  Apple's own, trust-cache-listed launchd** — because whatever its pre-check
  policies and the ad-hoc branch's callback consult (the trust caches) is
  **not loaded at boot on 27.0.1**, while the identical 27.0 flow loads it
  (booting even ldid-shaped re-signed binaries).
- The StaticTrustCache files themselves are format-identical between builds
  (same size 91441, same TCTF structure, only hash values differ), and the
  restore delivers them as personalized TSS assets (`StaticTrustCache` in
  `restore.c`'s asset list). The failing console's
  `magazine[…]: failed to read nonce slot data: 2` (ENOENT — a nonce *slot*
  missing) vs 27.0's errno 13/6 points at the **personalization/nonce-slot
  handshake differing for 27.0.1's images against the fixed 26.4 SEP/TXM**.
- Open wrinkle: the iPad16,1 27.0.1 guest booted today, so either its
  restore personalized differently or the iPad tree configures TXM policies
  to tolerate an empty magazine. Worth one look when fixing.

**The fix surface is the restore's TSS/personalization of 27.0.1's trust
caches** (nonce slot selection in `VPhoneRestore`/tss code), or the
kernel/TXM patch route (force-pass the `sub_30BAC` pre-check walk, which
covers every branch of the ladder at once).

## The patch: `txm-boot-precheck_admission` (2026-10-04) — **VERIFIED, 27.0.1 boots**

Machine `t271x` (iPhone17,3 + 27.0.1 + cloudOS 26.4 + the patch, bundle
`2.5.0-local.94f7c22c`): restore, CFW install, first boot — `running`,
`panicked: false`, no selector-24 line in the console, and vphoned answers
`device.info` live. The acceptance bar is met. (Note for retesting: the
boot-chain TXM is flashed at restore time — a machine restored before the
patch keeps booting the old TXM until re-restored.)

`TXMDevPatcher.patchPrecheckForcePass()` forces the pre-check walk
(`sub_30BAC`, 187.100.3 offsets; `sub_428F0` in 217.0.2) to its PASS exit, so
the selector-24 caller accepts at the top of the ladder and none of the
fallback branches — ad-hoc, CMS gate, third fallback — ever run.

**Reveal procedure** (how the site was found and how to re-find it on a new
TXM):

1. Decompress `Firmware/txm.iphoneos.research.im4p` from the merged restore
   tree (it is cloudOS 26.4's 187.100.3; the iPhone IPSW's copy is overwritten
   by `mergeCloudOS` — see above).
2. Scan for `mov x17, #0x7e51` (movz encoding `0xD28FCA31`) followed by
   `blraa x8, x17`. On 187.100.3 this hits three times; only the pre-check
   walk's function also contains the post-indexed `ldr x22, [x20], #0x40`
   policy-table walk before the hit (the other two hits share an unrelated
   function at `0x32d78`).
3. Walk back to the `pacibsp` prologue; the two instructions after it are
   `mov x19, x1 ; mov x20, x0` — the patch overwrites the four instructions
   that follow with `mov w8, #0xa ; strb w8, [x19] ; mov w0, #0x90 ;
   b <epilogue>` (epilogue = the `retab`'s preceding `ldp x29, x30`).
   `0x90` is the walk's own PASS status (byte 1 clear); `0xa` is the
   validation-type byte the table-tolerated path writes to the out param.

**Validation:** constant words are capstone round-trip verified and frozen in
`ARM64EncoderTests`; the anchor pair resolves to exactly one function on
187.100.3; the boot test on `t271` (iPhone17,3 + 27.0.1 + the patched bundle)
is the acceptance bar. The patch is declared `txm-boot-precheck_admission`
(bootchain set, `iOSBase: .major(27)`, bootEssential) — on 27.0 the walk
already admits everything, so the patch changes bytes but not behavior.

## Fix options and what the 2026-10-04 experiments proved



1. **Reproduction done** (machine `t271`, iPhone17,3 + 27.0.1 + release
   2.5.0): identical `0x12491` panic — the trigger is 27.0.1-specific, the
   WIP-bundle theory is dead. (An iPhone-class 27.0 guest booted the same
   day on the same Mac.)
2. **`style: .appleAdHoc` re-signing — implemented and tested.** All three
   `VPhoneSigner.sign` call sites in `VPhoneCustomFirmwareInstaller.swift`
   now pass `style: .appleAdHoc`. Deployed through
   `vm set-bundle t271 2.5.0-local.4f3be451` + `cfw install` (note:
   `vm create --from installCFW --bundle …` does **not** rebind the machine —
   verify `launchpad.json` and the on-disk `flags=0x2` before believing a
   test). Result: the on-disk launchd carries `flags=0x2(adhoc)`, the
   `0x12491` CMS-gate error is **gone** (the ladder analysis held), but init
   still dies — now with `selector: 24 | 0x02 | 0x22 | 3` (**0x32202**), the
   error after the *whole* ladder is exhausted: pre-check walk → ad-hoc
   branch `sub_30B1C` → third fallback `sub_30A78` all rejected, and the
   table tolerance bytes are clear. The signing change is correct but not
   sufficient; it is **not yet regression-tested on a booting guest**
   (patchtest-iphone is the candidate).
3. **The layer under the ladder: trust caches never load in the 27.0.1
   guest.** The failing console uniquely shows, before the kill:
   `TXM [Error]: Errno: selector: 45 | 78`, `AppleImage4: failed to set boot
   uuid in supervisor: 78`, `magazine[cptx]: failed to get nonce: 13`,
   `magazine[c1bt]: failed to get nonce: 6`, and
   `is_root_hash_authentication_required: disk1s1 Root Volume, root hash
   authentication is required`. Every passing machine's console
   (patchtest-iphone 27.0, both iPads 26.6.2) has **none** of these and
   instead shows a successful runtime
   `AppleMobileFileIntegrityUserClient::loadTrustCache … requesting a trust
   cache load`. With the trust-cache magazine empty in TXM, the selector-24
   pre-check policies have nothing to admit against, which is what pushes
   the re-signed launchd into the ladder at all. Why the 27.0.1 magazine /
   nonce path fails against the fixed 26.4 SEP/SPTM/TXM (format change?
   new nonce protocol?) is the open question — that is where a real fix
   lives, not in the signature shape.
4. **A new TXM dev patch** forcing the `sub_30774` wrapper-not-found exit to
   pass is now the wrong lever: the ladder has three more rejection points
   after it (0x32202 proves it). A patch that force-passes the *pre-check*
   walk would cover all of them at once, but it is a policy-grade change
   (see `Skills/authoring-patch-sets/SKILL.md`).
5. **Stop discarding the iPhone's TXM**: exclude `txm.*` from the cloudOS
   `Firmware/*.im4p` overwrite so the guest boots the TXM contemporary with
   its userland (217.0.2 on iOS 27.x). Not a cloudOS version bump (none is
   possible; nothing after `26.4-23E5207q` carries `vphone600ap`). Risk: the
   booted TXM must pair with cloudOS 26.4's `sptm.vresearch1` and the 26.4
   kernel's selector call convention; needs an empirical boot.
