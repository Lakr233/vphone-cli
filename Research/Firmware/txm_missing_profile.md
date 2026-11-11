# Development CMS signatures with no TXM profile association

Missing-profile compatibility is part of `txm-cfw-executable_remap`, recorded
as its `.missing_profile` site. Restoring native classification exposes this
conflict with `kernel-boot-amfi_trustcache`, so the same patch now includes the
correction whenever that AMFI bypass is enabled. Standard selects both patches;
there is no separate profile checkbox. With AMFI bypass disabled, profile
association follows its native path and the profile validator is left intact.

The combined patch retains native classification's version-independent
selection and requires every needed site to match uniquely before emitting
any records. The signature layout and error path were inspected and replayed
on pristine cloudOS 26.1, 26.2, 26.3 and 26.4 TXMs. No live VM has received
the profile correction yet.

This is a waiver of **missing provisioning-profile authorization**, not a
repair of profile registration. Native type 4 remains type 4. Non-null profile
checks, CMS classification, earlier finalizer checks, and executable remapping
checks retain their existing instructions.

## Reproduction

The affected guest uses cloudOS 26.4 and iOS 26.6.2. Launching an App whose
main executable retains its Apple Development CMS signature failed with
`NSPOSIXErrorDomain 85` and:

```text
TXM [Error]: CodeSignature: selector: 24 | 0xA6 | 0x12 | 1
```

The embedded profile was present, and misagent returned its matching UUID in
the failure window. That does not prove association with the TXM signature
object. Guest logs do not name the rejected Mach-O. The main executable and
AMFI fast path are a strongly supported attribution, not a live observation
of that object's type and profile pointer.

## Binary evidence and conflict

The original images were extracted from the locally cached cloudOS 26.4 IPSW.
Addresses below document this one image; production matching uses Capstone
operands and control flow, not those addresses.

| Object | Identity |
| --- | --- |
| TXM | `TrustedExecutionMonitor_Guarded-187.100.3` |
| TXM UUID | `B5296327-F14E-3430-9341-F452A4C9B571` |
| TXM SHA-256 | `819861b6b534b6dc53287b010e822b9d93633d07a29b6e5b968c076929ebfbc1` |
| Kernel collection SHA-256 | `86895a2eebeb7fcfb68bcd60f2d7e685687faea07ee31166fb58c872b38e0d92` |
| Embedded kernel UUID | `784F88D3-2AF5-3D4A-AB00-365607646E44` |
| AMFI UUID | `BAC1A875-32B3-3631-820E-791F9AD68B4E` |

The AMFI patch makes `AMFIIsCDHashInTrustCache` always return 1, also writing
metadata 1. In this kernel, the patched function is at
`0xfffffe0007de0294`. Its caller at `0xfffffe0007de7b80` reports a hit to the
vnode checker. The branch at `0xfffffe0007de9d80` enters normal CMS validation
only on a miss. The hit path bypasses the profile-submission call at
`0xfffffe0007deaf58`; the latter eventually calls `csblob_register_profile`
at `0xfffffe00092365c8`, then TXM profile association via selector 20.
XNU's `bsd/kern/ubc_subr.c` documents the same order: AMFI associates the
profile before the independent monitor validation.

The remap patch restores genuine TXM cache queries and keeps native CMS
classification. A Development CMS signature can therefore remain type 4,
requiring the association that AMFI skipped. The TXM finalizer at file
`0x32088` dispatches type 4 to file `0x31348`. That validator begins with:

```asm
ldr  x8, [x0, #0x108]   ; associated profile
cbz  x8, missing_profile
; native entitlements, TeamIdentifier and DeveloperCertificates checks
...
missing_profile:
mov  w0, #0x12a6
movk w0, #1, lsl #16   ; 0x112A6
; shared epilogue
```

The association helper stores the profile into signature `+0x108` at file
`0x32308`; disassociation clears it. The finalizer's type field is `+0x101`
and its finalized field is `+0x102`. The unique A6 error matches the launch
log and a host replay of the pristine instructions.

## Compatibility patch and limits

The profile site replaces the two instructions at file `0x313cc` with
`mov w0, #0xa6; nop`, returning this component's native success status only
from the null-profile exit. The native finalizer then stores type 4 and
returns 3. The patch does not invent a profile, change the category to 5/10,
or force the entire selector 24 handler to succeed.

Discovery requires the unique A6 error and shared epilogue, its single
null-profile predecessor, the existing non-null success/error convergence,
and the sole caller in the finalizer's type-4 arm. An extra predecessor,
changed dispatch, missing shape or ambiguity throws before any bytes are
applied. `patchExecutableRemap()` resolves this site together with every
classification/library site before selecting the base bypass or emitting any
records. `findAll()` also clears pending records on a failed discovery, so a
retry cannot apply only half the plan. Disabling `txm-cfw-executable_remap`
disables the profile correction with it.

The signature category field comes from the native classifier's pre-check
arguments, as in the upstream 26.1–26.3 classifier support. The locator requires
the finalizer to read that same field and publish to the next byte. It also
requires the validator's null check to load the following aligned profile
pointer (category + 7). This keeps the two inspected layouts consistent without
selecting a fixed field offset by firmware version.

Missing-profile Apps consequently do not receive the entitlement, Team ID or
developer-certificate authorization that a profile would supply. Keeping
their CMS classification is not a substitute for that authorization. This
tradeoff is part of the combined research compatibility policy. When a profile
is associated, every native check of that profile remains in place.

## Verification

### Old-version corpus

On 2026-11-10 the old images were acquired directly from the Apple cloudOS URLs
`cloud261`, `cloud262` and `cloud263` in `VPhoneFirmwareCatalog.swift`.
`VPhoneRemoteZip` range requests fetched `BuildManifest.plist` and
`Firmware/txm.iphoneos.research.im4p`; `vphone-cli fw im4p-extract` produced
the raw images below. The release variant is not the tested research TXM.

| cloudOS | Build | Raw TXM SHA-256 |
| --- | --- | --- |
| 26.1 | 23B85 | `ec68dc5a1ec77d8399365f7164e0384539c75e06ed9555f793ce5ff34a9c1db6` |
| 26.2 | 23C55 | `17e401fd6c1b07f026acc43509eabfc87c96d3673b86165d1d3af53dc5026b6d` |
| 26.3 | 23D129 | `62f40b9cd32a2a035899a925d51f2573bb603db216fc5405a3d9ad48b180a1d2` |
| 26.4 beta | 23E5207q | `819861b6b534b6dc53287b010e822b9d93633d07a29b6e5b968c076929ebfbc1` |

All three old TXMs identify as `TrustedExecutionMonitor_Guarded-182.40.3`.
Their profile validators and finalizers have identical instructions, relocated
by `0x20` in 26.2/26.3. The full images have different hashes and are tested
separately, including the combined patch, parser/classifier, finalizer and
ordinary-library compatibility. File offsets below are evidence and pinned
test inputs only:

| cloudOS | Profile validator | Null-profile exit | Finalizer | Published-type getter | Category / finalized / profile fields |
| --- | --- | --- | --- | --- | --- |
| 26.1 | `0x30cc4` | `0x30d48` | `0x319e0` | `0x31cb8` | `0xa1` / `0xa2` / `0xa8` |
| 26.2–26.3 | `0x30ce4` | `0x30d68` | `0x31a00` | `0x31cd8` | `0xa1` / `0xa2` / `0xa8` |
| 26.4 beta | `0x31348` | `0x313cc` | `0x32088` | `0x32360` | `0x101` / `0x102` / `0x108` |

### Native replay

The focused Xcode tests cover relocated discovery, missing/ambiguous/modified
control flow, selection of the combined patch, conditional inclusion with AMFI
bypass, and failure without partial records. The complete-image tests pin the
pristine TXM hash before executing native code. Isolated profile replay changes
only the reviewed 8-byte region; combined-image comparison checks every remap
site and verifies that disabling AMFI bypass removes only those 8 bytes.

Native replay uses both a generated installer signature and an optionally
supplied CMS-signed executable (`VPHONE_PROFILE_APP`). Type assignment and
policy callbacks are controlled inputs; this is not native CMS certificate
classification or a full launch. The original affected App's main executable
was supplied in the initial standalone run. The merged revision repeated the
replay with a local CMS-signed `VPhoneExecutableRemapDemo` executable. The
four-version corpus repeats that replay on each pinned image. The controlled
results are the same across the four versions:

| Controlled input | Original TXM | Only the new compatibility patch |
| --- | --- | --- |
| Profile validator, null profile | `0x112A6` | `0xA6` (success) |
| Finalizer, type 4, null profile | `0x112A6`, finalized type 0 | `3`, finalized type 4 |
| Finalizer, type 5, null profile | `3`, finalized type 5 | Same |
| Non-null, untrusted profile | `0x12225` | Same |
| Earlier platform-only policy | Rejected | Rejected |

The generated ldid signature independently hits `0x130A1` at the earlier
hash-flags check in pristine TXM. The isolated A6 patch preserves that rejection;
it does not replace the existing A1 bypass. Existing remap tests run the
combined plan, including that bypass, on ldid/ad-hoc admission, malformed
SuperBlobs, category behavior and library compatibility.

On 2026-11-10, the follow-up against upstream `9d9d796b` passed **83 tests in
8 suites** (135 parameterized executions), including
both TXM suites and the required version, selection, declaration, plan, gate
and bundled-catalogue suites, with **zero skips**. Each of the four original
TXMs matched its SHA-256 above before native execution. Complete-image
comparison checks all nine changed instructions relative to the remap-disabled
standard preset; disabling AMFI bypass restores only that image's 8-byte
null-profile exit. The malformed profile fixture rejects direct discovery, `findAll()` and an
`apply()` retry without leaving records or changing bytes.

The `VPhoneCommand` workspace build also passed. The catalogue tests verify
that standard enables `txm-cfw-executable_remap`, and no standalone profile
declaration remains. Other component reference-corpus tests were not run
(`ipsws/ref_extract` is absent). No restore, live TXM replacement, App
re-signing or successful guest launch is claimed.

For Xcode replay, set `TEST_RUNNER_VPHONE_REMAP_TXM` to the pinned raw 26.4
TXM, `TEST_RUNNER_VPHONE_REMAP_TXM_26_1`, `_26_2` and `_26_3` to the respective
old raw images, and `TEST_RUNNER_VPHONE_PROFILE_APP` to a CMS-signed Mach-O.
Without those inputs, the corresponding image/CMS tests are not run.

### Relationship to the lost-execute-permission regression

The original remap issue involved high-category restrictions after a fabricated
cache hit. XNU clears X on association failure while the map-insertion caller
discards the error; see [the remap investigation](txm_executable_remap.md).

The association handler at TXM file `0x1eb10` reads finalized type through the
native getter at `0x32360` (signature `+0x102`). The branch at `0x1ec14` routes
types below 6 to ordinary CodeDirectory bounds instead of the high-type
whole-executable-segment requirement. The main-image alias path at `0x1ee78`
also distinguishes types <=5 from higher types. The new patch leaves those
instructions and real cache queries intact. Its admitted type 4 stays type 4;
it does not restore a fabricated cache hit or force type 10.

The CMS replay calls that exact mapping-type getter and verifies that a newly
admitted signature publishes 4. This and the 8-byte-only image difference
support preservation of the remap fix; live page mapping remains unverified.

## Deployment

Use a new test VM and a bundle built from this change. For a test VM starting
from the standard preset, the intended selection is:

```zsh
vphone-cli fw set-patches cms-profile-test --preset standard
vphone-cli fw patches cms-profile-test
```

Check that `txm-cfw-executable_remap` and `kernel-boot-amfi_trustcache` are enabled,
then include the new TXM in that test VM's normal firmware-patch/restore
workflow. `fw set-patches` alone
only changes intent. Current fleet delivers TXM through a restore; `cfw
update-kernel` and `cfw update-environment` do not install it. A restore erases
guest data, so do not use the existing development VM as the first experiment.

Runtime acceptance: first launch a small Development CMS-signed App and confirm
the A6 failure disappears. Then query actual destination RX and execute original
main/framework code after partial, whole and repeated-alias remaps. The earlier
remap PR's VM results predate the integrated profile correction and do not
validate it.
