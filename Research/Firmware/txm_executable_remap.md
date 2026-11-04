# TXM signature classification and executable remapping

Ordinary App code can lose execute permission after `vm_remap` in a research
VM even when the call reports success and RX. The destination actually becomes
R/R, `vm_protect(RX)` returns 2, and execution fails with `CODESIGNING / Invalid
Page`. This patch restores original-code remapping for the tested installed
main executable and embedded framework by correcting TXM classification and
allowing the installer's signatures through the existing research fallback.
It also deliberately relaxes ordinary-library Team ID matching.

**Scope:** `txm-cfw-executable_remap` is selected by the standard preset,
non-boot-essential, and has no iOS/cloudOS version gate. It requires unique
semantic matches in pristine TXM; missing or ambiguous shapes stop patching.
Runtime reports cover iOS 26.6.2 and iOS 27.1 on a VRESEARCH1 kernel; other
combinations are not established by these results. This revision removes the
iOS 27 forced pre-check admission and uses the same native classification path
there. The tester reports successful startup and no App crashes with the
replacement; measured remap results and their limits are detailed below.
It is research compatibility, not stock-iOS signature enforcement. In particular,
the patched VM also executes modified framework code that stock iOS rejects; see validation
below. The signer, installer and existing Flutter AOT fallback are unchanged.

## Cause and policy

The historical trust-cache bypass replaces a 20-byte cdhash comparison with
`mov x0, #0`, fabricating a hit during a nonempty v2 cache search. Pre-check can
then assign a high type to ordinary code. The investigated probe was type 9;
its individual cache admission was not traced live. Native association treats
types >=6 differently: they require the whole executable segment and restrict
second main-image aliases. Those gates explain the observed rejection of a
partial remap and subsequent alias registration.

XNU's `vm_map_store_entry_link` discards the association result, while
`vm_map_entry_cs_associate` clears X on failure. Thus syscall success alone is
insufficient; tests must query actual protections and execute the destination.
The patch keeps the genuine cdhash lookup and uses the existing hash-flags
bypass instead. Successful cache/CMS classification retains native types.

Two compatibility cases become visible once cache misses are real:

- The default installer writes ldid-style signatures with flags 0 and no CMS.
  They are neither `CS_ADHOC` nor normally CMS-signed. Redirecting only the
  missing-wrapper exit to Apple's research fallback admits them as type 5
  under the native container marker, otherwise type 10. Ad-hoc fallback remains
  type 10; it is not relabelled to make remaps pass.
- Default re-signing also omits the CodeDirectory Team ID. Native image-pair
  validation returns `0x62407` for a missing main ID, `0x72407` for a missing
  library ID, or `0x82907` for unequal IDs. This can leave framework code without
  X before remapping. The patch skips that comparison for ordinary library
  types 3–5, including one/both IDs absent or unequal present IDs. It retains
  category ordering, finalized-signature, policy-context and main/library-role
  checks. Types 1/2 and >=6 use their existing paths.

This Team ID exception permits cross-team loading; it does not authenticate a
common signer. **Follow-up: preserve existing CodeDirectory Team IDs during
vphone re-signing, then reassess this exception.** Do not fabricate an ID or
substitute an entitlement. Separately pushed hot-reload libraries may retain
their own Team ID, so testing only two identity-less images is insufficient.
CMS/profile admission and category ordering can still reject a library before
it reaches the relaxed comparison.

## Replacement of the iOS 27 pre-check override

The former `txm-boot-precheck_admission` wrote type 10 and returned success
before CMS/ad-hoc classification or the path-dependent type-5 fallback. It kept
ordinary App code under the high-type executable-range and main-image alias
restrictions even with real cache queries. This revision removes its declaration,
implementation and invocation. The native pre-check remains byte-identical to
pristine TXM; iOS 26 and 27 now produce the same patched image from the same TXM.

Replacement assessment on the pinned image: with no policy callbacks, execute
the outer classifier and final validator on the bundled signer's ldid and
Apple ad-hoc signatures. The former
returns the historical `0x12491` without this patch; the latter returns `0x32202`.
With this patch, ldid signatures reach type 5 with the container marker and type
10 without it, while ad-hoc signatures reach type 10. These admitted cases also
pass final validation. This covers the two observed first-boot rejection paths
documented in [the iOS 27 investigation](txm_selector24_cms_gate.md), not the
underlying restore/trust-cache problem or a complete boot.

The replacement is deliberately narrower: with the CMS restriction flag at
policy `+0xd4` set, ldid admission still fails with `0x42291`; the former override
bypassed that check. The original VM's flag and callback state were not captured.
The subsequent iOS 27.1 report confirms original-code remapping, and the tester
reports successful startup and App loading. The exact historical iOS 27.0.1
pairing and every policy context have not been retested. Native ad-hoc/type-10
mapping restrictions remain.

## Patch sites and discovery

Examined image: `TrustedExecutionMonitor_Guarded-187.100.3`, UUID
`B5296327-F14E-3430-9341-F452A4C9B571`, paired with
`kernelcache.research.vphone600`, UUID `784F88D3-2AF5-3D4A-AB00-365607646E44`.
Original uncompressed TXM SHA-256:
`819861b6b534b6dc53287b010e822b9d93633d07a29b6e5b968c076929ebfbc1`.

The table gives file offsets for review and pinned-image tests only. Production
locators use Capstone operands/control-flow, not these offsets or byte strings.
Relative to the patch-disabled standard preset, seven instructions differ:

| Site | Enabled behavior |
| --- | --- |
| `0x2c7e8` | Keep original cdhash-comparison BL instead of the fabricated cache hit. |
| `0x31a60` | Select existing hash-flags bypass (`mov x0, #0`). |
| `0x30a28` | NOP CMS fallback tolerance gate after certificate-policy miss. |
| `0x32070` | NOP ad-hoc fallback tolerance gate; fallback stays type 10. |
| `0x30824` | Redirect absent-CMS `cbz x0` from `0x30860` to fallback at `0x30a24`. |
| `0x33080`, `0x33084` | Skip ordinary-library Team ID comparison with `mov w21, #7; b 0x32f50`. |

To recover and validate the sites on the examined image:

1. Find the pre-check through its authenticated callback (`mov x17, #0x7e51;
   blraa`) and result codes. Follow its direct caller into the native
   `CS_ADHOC`/CMS split. Recover both tolerance gates from that control-flow,
   their policy-field relationship, failure exits and native type stores.
2. In the CMS classifier, recover the slot `0x10000` / magic `0xfade0b01`
   lookup and absent-wrapper exit. A present wrapper still traverses its parse
   and digest checks; the preceding SuperBlob validator rejects malformed slots.
   Keep the second CMS restriction and the path marker selecting type 5/10.
   The native marker uses `/private/var/containers/Bundle/`; no path list is added.
3. Locate ordinary-library comparison via category dispatch, Team ID reader
   calls, rejection codes and shared return path. Require the preceding category
   comparison and special type-1/2/>=6 dispatch to match before changing it.
4. Resolve all sites uniquely before emitting the revision. Require an original
   cdhash BL; reject already-bypassed input and missing/ambiguous shapes without
   falling back to fabricated cache hits. Start from pristine extracted firmware.

Association (`0x1eb10..<0x1efe4`) and final validation
(`0x32088..<0x321f8`) remain byte-identical to the original. In particular,
`0x1ec14` retains the high-type executable-range requirement and `0x1ee78`
retains its main-image alias restriction. Unchanged instructions do not prove
identical runtime enforcement after classification and admission change.

## Validation

The remap, catalog and patch-model suites passed **73 tests**, including the
optional full-image test. The iOS 26.6.2 validation also included a complete
`VPhone` bundle build, bundle admission and deep strict codesign verification.

- Relocated fixtures check exact output, changed/missing/ambiguous shapes,
  rejection without partial emission, version-independent selection and explicit
  disabling.
- The supplied original image checks all seven instruction differences and
  unchanged association/final-validation code. On arm64, tests execute its real
  SuperBlob parser, CMS classifier and final validator using the default signer,
  including truncated/malformed signatures and retained policy restrictions.
- Native image-pair execution covers 18 constructed inputs: absent/unequal
  IDs, types 3/4/5, and retained rejection of category downgrade, unfinalized
  signatures, wrong roles or different contexts. Types 6/8/9/10 retain their
  results; type-1/2/7 paths are covered by byte comparison, not runtime inputs.
  Host tests do not execute guest cache/profile setup or page mapping.

Supply the pristine uncompressed TXM above; without it the full-image test is
skipped. Xcode forwards `TEST_RUNNER_VPHONE_REMAP_TXM` to the test process:

```zsh
export VPHONE_REMAP_TXM=/absolute/path/to/txm.original.bin
export TEST_RUNNER_VPHONE_REMAP_TXM="$VPHONE_REMAP_TXM"
xcodebuild -project VPhoneExecutable/VPhoneCommand/VPhoneCommand.xcodeproj \
  -scheme FirmwarePatcherTests -configuration Debug \
  -destination 'platform=macOS,arch=arm64' -derivedDataPath .build/XcodeCommand \
  -only-testing:FirmwarePatcherTests/TXMExecutableRemapTests \
  -only-testing:FirmwarePatcherTests/FirmwarePatchSetCatalogTests \
  -only-testing:FirmwarePatcherTests/VPhonePatchGateTests test
```

A standalone validation app remaps known functions from its main executable
and embedded framework, queries actual protections, and calls the remapped
functions to check their return values. Separate cases exercise signed data,
modified private code, anonymous memory and system-library mappings. These
runtime observations are separate from the host unit tests above; the validation
app and raw captures are not included in this contribution.

VM reports: iOS 26.6.2 / 23G90 and iOS 27.1 / 24A94425. Both identify a
Darwin 25.4.0 VRESEARCH1 kernel, 16 KiB pages and no debugger.
Stock comparison: iPhone18,3 / iOS 26.2 / 23C55, also without a debugger.

| Original-code execution | Stock iOS 26.2 | VM iOS 26.6.2 without patch | VM iOS 26.6.2 patched | VM iOS 27.1 replacement |
| --- | --- | --- | --- | --- |
| Main executable | 14/14 | 0/14 | **14/14** | **14/14** |
| Embedded framework | 14/14 | 0/14 | **14/14** | **14/14** |

Partial/whole, private/shared and fixed/overwrite execution succeeds. All four
16-alias repeat cases pass in both patched reports. All 28 execution cases have
actual RX mappings, correct return values and passing recorded checks.
With native classification but without Team ID tolerance, main execution passed
while the framework source lacked X. Enabling
the tolerance restored framework execution with unchanged code and signatures
(flags 0, no CMS, no Team ID). This improvement does not depend on adding an
identity. In the VM, `vm_remap` resolves through vphone's SystemHook compatibility
library. The runtime reports contain no installed TXM hash/commit, so they do
not independently verify the deployed firmware or reveal per-image TXM types.

The successful VM captures use matching main/framework CodeDirectory hashes.
The main executable carries `get-task-allow` and
`jb.pmap_cs_custom_trust = PMAP_CS_APP_STORE`; the embedded framework carries
neither entitlement. The custom-trust entry is absent from the earlier
patch-disabled and stock-device captures. These are signature inputs, not an
observed TXM type, and the runtime comparison is not an isolated patch-only
experiment across identical signatures. The host full-image tests separately
isolate the classification changes.

The reports contain 226 and 298 records respectively, with no interrupted cases.
Each includes 28 execution and six boundary cases; both complete 186 mapping
observations. The iOS 27.1 report also skips 78 system-image ranges because of
alignment or unavailable CodeDirectory bounds, versus six skips on iOS 26.6.2.
Skipped ranges are not passes. System images are observed for permissions only;
some remaps report protection values that differ from the queried destination.
The successful ordinary-code execution results do not establish system-code
remapping compatibility.

Startup and App-loading success for the replacement are tester-reported,
separate from the probe's execution records. Repeated cold boots, hot reload
and a broad application regression suite are not established by these reports.

**Known boundary difference:** modifying a framework private alias, requesting
RX and calling it succeeds in both patched VM reports (the modified function
returns its expected value). Stock iOS returns 2 from the RX request and leaves RW. The
probe confirms the original source bytes are unchanged. Earlier VMs lacked X before this
case, so these reports do not isolate whether the Team ID exception causes the
difference or exposes existing research/JB behavior. Do not claim stock policy
alignment or that all modified signed code remains non-executable.

Signed main/framework data still cannot become executable, and the main private
code alias still rejects RW. libffi partial/whole remaps remain R/RX and remapped
ObjC trampoline pages remain R, matching the device. Anonymous RX/RWX is more
permissive in the VM, including before this patch. OS versions and signing differ
between device and VM. Separately pushed CMS-signed hot-reload libraries, real
certificate/profile-backed Team ID mismatches and every TXM type are not
established by this probe.

## Deployment and references

Enable/disable the single `txm-cfw-executable_remap` identifier in the patch
preset, then regenerate TXM from pristine firmware and deploy through the normal
restore/new-template flow. An environment update cannot replace TXM. Disabling
selects the historical base trust-cache bypass, but cannot restore the removed
iOS 27 pre-check override and may prevent iOS 27 startup. To recover the former
behavior, restore with the previous build. Publishing a new bundle or updating
the guest environment alone does not replace the TXM already flashed into a VM.

- [Apple app code signing](https://support.apple.com/guide/security/app-code-signing-process-sec7c917bf14/web)
  describes signature and library validation; the research exceptions above are deliberate.
- [XNU vm_map.c](https://github.com/apple-oss-distributions/xnu/blob/f6217f891ac0bb64f3d375211650a4c1ff8ca1ea/osfmk/vm/vm_map.c)
  provides source context for remap/association, not the exact guest kernel revision.
- [Dart DuplicateRX](https://github.com/dart-lang/sdk/blob/03c24e5e495913b17f3584510ed7944a88438460/runtime/vm/virtual_memory_posix.cc#L836)
  uses fixed/overwrite private remapping of existing iOS RX code.
- [Apple libffi](https://github.com/apple-oss-distributions/libffi/blob/72e95a49029b75b2a0de094477f8410a32013c87/src/closures.c#L206)
  documents the whole-dylib remap requirement, supporting preserved high-type restrictions.
- [Existing Flutter AOT fallback](../Guest/flutter_aot_remap_compatibility.md)
  remains a separate, unchanged guest compatibility path.
