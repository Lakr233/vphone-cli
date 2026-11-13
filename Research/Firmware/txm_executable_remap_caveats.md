# TXM executable remap — review notes and deployment caveats

Follow-up review of `txm-cfw-executable_remap` (merged in #831, which replaced
the forced type-10 `txm-boot-precheck_admission`). The Release bundle carrying
the patch was built and exercised on freshly restored guests. This note records
what was verified, one regression surface the change opens, and the precautions
for deploying it. It is a companion to [the patch assessment](txm_executable_remap.md);
read that first for the mechanism and the host-side evidence.

## Summary

The change is sound and fails closed: every site requires a unique semantic
match and the patcher throws rather than emitting a partial rewrite. Boot on
iOS 27.0.1 — the case the removed patch originally fixed, and which the patch's
own notes did not retest — is confirmed working. Instruction matching is
Capstone-derived and replacement bytes come from the project encoders, so it
follows the kernel/TXM patcher guardrails.

One behavior change is **not covered by the host tests or the runtime probe**:
a **CS_ADHOC** standalone executable (`codesign -s -`, CodeDirectory flags
`0x2`) that has an injected dylib mapped executable in its address space is now
killed at launch. The removed forced-admission patch masked this. Because the
patch is merged, this regression is now in `main`.

## Verified

Release bundle carrying the patch, installed without moving the default, used to
create standalone guests.

| Check | Result |
| --- | --- |
| iPhone17,3 iOS 27.0.1 (24A446) create → first boot | Boots to a ready vphoned; no `unexpected SIGKILL of init` |
| iPad16,1 iOS 27.0.1 (24A446) create (via template) → boot | Same |
| Patch log | 16 TXM patches, including the four `txm-cfw-executable_remap` sites; no `precheck_admission` |
| ldid- and `codesign -s -`-signed dylibs `dlopen`'d into a **signed app**, inline-hooking the app's main binary, an embedded framework, and a shared-cache function | All reach RX and return correctly |
| A **standalone `codesign -s -` executable** (flags `0x2`) with an injector dylib mapped into it | `EXC_BAD_ACCESS / KERN_PROTECTION_FAILURE` in the injector's own `__TEXT` (an `R--` COW page that never becomes RX); SIGKILL, `CODESIGNING / Invalid Page` |
| The same executable re-signed with `ldid -S` (flags `0`) | Runs |

The iOS 27.0.1 boot result closes the gap the assessment left open ("the exact
historical iOS 27.0.1 pairing has not been retested").

## The regression surface

Same device, same OS, same injector; only the bundle's TXM differs:

| | bundle before the patch (still has `precheck_admission`) | bundle with the patch |
| --- | --- | --- |
| A given `codesign -s -` standalone executable | runs | SIGKILL at launch |
| `dash` (a CS_ADHOC bootstrap shell) crash reports | 0 | 28 |

The `dash` crashes show this is not one binary but the general shape:
**a CS_ADHOC standalone executable that gets code mapped executable by an
injector**. Native classification keeps CS_ADHOC on the ad-hoc fallback at
type 10 and preserves type 10's executable-range and alias restrictions, so the
injected page never reaches RX. The former forced-admission patch returned
success before classification, which is why these processes ran before. A
plain-ad-hoc CodeDirectory (`ldid -S`, flags `0`) classifies natively and is
unaffected — this matches the injector libraries' own signing (flags `0`).

Dylibs injected into an already-signed host application are not affected when
the injected dylib itself is ldid-signed (flags `0`). They **are** affected when
the injected dylib is CS_ADHOC and the host is one of Apple's ad-hoc apps — see
the pre-check admission note under the TXM table in
[the patch comparison](../0_binary_patch_comparison.md).

## Deployment caveats

- **TXM is fixed into the VM at flash time.** Changing the bundle, running an
  environment update, or running `fw patch` followed by `cfw install` does not
  replace it (`fw set-patches`: "LLB, TXM, DeviceTree: only a restore"). Only a
  fresh restore / new template picks up a TXM change, so existing machines keep
  the old behavior and "upgrade the bundle" does not validate the patch. Check
  the TXM section of `PatchReceipt.plist` (writer `restore`, its date) before
  attributing a result to a TXM change. Good for staged rollout; bad as a
  verification shortcut.
- **Disabling the patch alone does not restore the old behavior.** Turning
  `txm-cfw-executable_remap` off selects the historical base trust-cache bypass
  only and may stop iOS 27 from booting. To get the old pre-check admission,
  restore with `--allow txm-exp-precheck_admission` (it supersedes this patch)
  (iOS 27 only); see the pre-check admission note in
  [the patch comparison](../0_binary_patch_comparison.md).
- **Template key change.** The boot-chain patch set changed, so templates built
  by older series are marked stale and an identical create resolves to a
  different boot-chain plan; templates must be rebuilt, which re-restores.
- **CS_ADHOC tooling in the guest.** Any standalone process signed with
  `codesign -s -` that relies on an injector mapping executable code must be
  re-signed with `ldid -S` (bare CodeDirectory, flags `0`) once the guest runs
  firmware carrying this patch. Injected dylibs should already be ldid-signed.
- **Team ID relaxation.** The patch deliberately skips ordinary-library (types
  3–5) Team ID matching, permitting cross-team library loading. Acceptable for a
  research VM, but it is a real relaxation; track the follow-up to preserve the
  CodeDirectory Team ID during re-signing and then narrow it.
- **More permissive than stock.** Per the assessment's own boundary note, a
  modified framework private alias can reach RX here where stock iOS returns 2.
  This is research compatibility, not stock-policy fidelity; passing probes do
  not prove stock behavior.
- **Strongest test is opt-in.** The full-image test is skipped unless
  `VPHONE_REMAP_TXM` points at the pristine uncompressed TXM; ensure CI provides
  it or the deepest check silently does nothing.

## Existing Duo guest: reported RX but actual R-only alias (2026-11-06)

A retained Duo guest demonstrates why the flashed TXM identity must accompany
an executable-remap report. Its running Core Bundle and guest environment were
`2.15.2-local.a7e398c8`, but its boot-chain bundle was `2.13.8`. The restore
receipt's TXM section, dated 2026-10-28, still listed both
`txm-boot-precheck_admission` and `txm-boot-trustcache_bypass`, with no
`txm-cfw-executable_remap`. These are deployment records, not a byte-level
attestation of the running TXM.

On iOS 27.1 (24A94425) / cloudOS 26.4 (23E5207q), Taobao 10.69.0 (59622514)
privately remapped a 16 KiB page of its main executable's RX trampoline code
into an aligned slot in its own reserve using `vm_remap`:

| Input or observation | Value |
| --- | --- |
| Target and source tasks | Both `mach_task_self()` |
| Size / mask | 16384 / 0 |
| Flags / copy / inheritance | `VM_FLAGS_FIXED | VM_FLAGS_OVERWRITE` / true / `VM_INHERIT_SHARE` |
| Source actual current / maximum | RX / RX |
| Return | `KERN_SUCCESS` |
| Returned current / maximum | RX / RX |
| Target actual current / maximum (`vm_region_64`) | R / R |
| Subsequent call | Instruction abort at target + 16; `KERN_PROTECTION_FAILURE` |

An application-scoped diagnostic fallback rebuilt only these unpublished
target pages with fixed anonymous allocation, copied identical source bytes,
and changed RW to RX. Each repaired page passed a readback permission and byte
comparison before returning to the caller. Execution then progressed beyond
the trampoline path. No TXM, kernel or other guest system file was changed.

This is additional evidence of the **legacy** classification failure, not a
failure report against #831 on newly restored guests. That pairing was not
restored with the replacement TXM, and the local workaround is not proposed as
a new global remap policy. The existing Flutter fallback is also deliberately
narrower than this main-executable, single-page shape. An app reaching its
homepage additionally required independent X1 exception-action compatibility
and an Intents metadata workaround; it is not an isolated TXM validation result.

For future reports, record the boot-chain bundle, TXM receipt, source and target
actual protections **as well as** the `vm_remap` return and protection outputs.
Do not use a Core Bundle/environment upgrade or a successful API return as
proof that the guest has the replacement TXM or that its alias is executable.
No application binary, raw account-bearing capture or private authorization
material accompanies this report.

## Recommendations

1. Add a guest probe for the uncovered case: a `codesign -s -` standalone
   executable that `dlopen`s a flags-0 dylib, maps its code page RX, and calls
   it; assert it is not killed with `CODESIGNING / Invalid Page`. This covers the
   surface the host unit tests and the dylib-into-app probe cannot.
2. State the CS_ADHOC behavior change — "re-sign standalone ad-hoc executables
   with `ldid -S`" — in the release notes, next to the "disabling cannot roll
   back" note and its "roll back by restoring a previous build" instruction.
3. Update the assessment from "iOS 27.0.1 not retested" to "27.0.1 boot
   re-confirmed" (see above).
4. Open an issue to track narrowing the Team ID exception (preserve the
   CodeDirectory Team ID during re-signing).
