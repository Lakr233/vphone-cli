# Standalone debug libraries and X1 instructions

## Failure

On an iPhone19,4 guest with iOS 27.1 `24A94425` and cloudOS 26.4
`23E5207q`, a development launch under LLDB stops before app entry:

```text
EXC_BAD_INSTRUCTION (code=1, subcode=0xdac1a7fe)
/usr/lib/system/introspection/libdispatch.dylib
libdispatch_init + 0: pacibsppc
```

The dispatch image UUID is `316BE3C0-B0A5-360D-B604-41132E0DEE18`.
The launch selects the introspection library with
`DYLD_LIBRARY_PATH=/usr/lib/system/introspection`, and inserts
`/usr/lib/libLogRedirect.dylib` and `/usr/lib/libViewDebuggerSupport.dylib`.
These files contain `ARM64E_X1` code (CPU subtype 12). Their PAuth_LR
instructions fault on the research VM's CPU.

The shared-cache converter cannot edit these standalone files. An attached
debugger can receive the instruction fault before launchd's inherited lowering
handler. Disabling the debug environment avoids loading some of the affected
images, at the cost of their debugging facilities.

The existing [task-exception preservation](x1_exception_actions.md) protects
in-process crash-reporter registrations. Its interposer deliberately forwards
remote-task operations unchanged; thread exception actions and direct Mach
calls are outside its scope. Static conversion is therefore still needed for
these libraries during debugging.

## Inventory and reveal procedure

Inspect `/usr/lib/system/introspection`, `/usr/lib`, the installed OS cryptex's
`usr/lib`, and standalone debug/GPU frameworks. Follow `LC_LOAD_DYLIB`
dependencies: the view debugger uses `DebugHierarchyFoundation`, and the
`/usr/lib` aliases for cryptex libraries do not identify the physical file to
patch. The exception-action investigation also identified FramePacing's
dynamically loaded `libMetalMetricsInterpose.dylib` dependency.

For each image copied privately from the guest or its matching restore images:

```zsh
xcrun otool -hv /path/to/copy/libdispatch.dylib
xcrun otool -L /path/to/copy/libdispatch.dylib
vphone-cli cfw patch-arm64e-x1 /path/to/copy/libdispatch.dylib
shasum -a 256 /path/to/copy/libdispatch.dylib
vphone-cli cfw patch-arm64e-x1 /path/to/copy/libdispatch.dylib
shasum -a 256 /path/to/copy/libdispatch.dylib
```

Keep the original basename when invoking the CLI. The two final hashes must
agree. The planner discovers code through function starts, exception metadata
and control flow; fault addresses and UUIDs above are evidence, not patch
anchors. It uses the existing X1 lowering semantics, which reduce PC-bound
return authentication and checked pointer arithmetic to the supported forms.

The iOS 27.1 private-copy measurements are:

| Image | Lowered instructions | Re-attested code slots |
| --- | ---: | ---: |
| `/usr/lib/system/introspection/libdispatch.dylib` | 2,042 | 66 |
| `/usr/lib/libBacktraceRecording.dylib` | 160 | 6 |
| `/usr/lib/libMainThreadChecker.dylib` | 54 | 3 |
| `/usr/lib/libRPAC.dylib` | 480 | 20 |
| `/usr/lib/libViewDebuggerSupport.dylib` | 526 | 41 |
| `/System/Cryptexes/OS/usr/lib/libLogRedirect.dylib` | 52 | 3 |
| `/System/Cryptexes/OS/usr/lib/libMTLHud.dylib` | 1,534 | 48 |
| `/System/Cryptexes/OS/usr/lib/libglInterpose.dylib` | 8,932 | 482 |
| `/System/Cryptexes/OS/usr/lib/libMetalMetricsInterpose.dylib` | 796 | 21 |
| `DebugHierarchyFoundation.framework/DebugHierarchyFoundation` | 592 | 20 |
| `GPUToolsCapture.framework/GPUToolsCapture` | 15,599 | 574 |
| `GPUToolsDiagnostics.framework/GPUToolsDiagnostics` | 246 | 12 |

The three framework paths are under `/System/Library/PrivateFrameworks`.
These twelve images total 31,013 instructions and 1,296 slots, with zero
unvisited candidates and byte-identical second passes.
All twelve lowered standalone files were also re-signed with the native
signer's Apple ad-hoc style, retaining their identifiers and merging their
existing entitlements; `codesign --verify --strict` accepted every output.
The MetalMetrics image is
`/System/Cryptexes/OS/usr/lib/libMetalMetricsInterpose.dylib`, UUID
`590883D2-21FC-33B5-B9FC-D7C55D3A78C7`, SHA-256
`3e510cb5ce4c5ad9e80e7a1f5089e9361e719db923bbcee283767dda20b1c2ba`.

## Installation and failure handling

`FirmwareGuestSystemPatchSet.arm64eX1DebugImages` is the shared inventory for
declarations, installation and CLI basename lookup. Each image has its own
selectable patch ID. The standard preset selects them. The installer examines
the installed bytes after the cryptex copy, so changing only the OS version
string is neither necessary nor sufficient to decide whether an image needs
conversion.

`CustomFirmwareArm64eX1Installation` handles both selection directions:

- A missing optional file or a valid image needing no conversion produces a
  `NotApplicable` guest receipt. No backup, signature rewrite or bundle sealing
  occurs. Ordinary arm64/arm64e images retain their bytes and inode.
- A selected X1 image is lowered and signed in a private buffer first. The
  CodeDirectory identifier and entitlements are preserved with the existing
  Apple ad-hoc signing style. Only then is the original saved as `.bak` and the
  live file replaced. Reapplication starts from that same original.
- Debug-library lowering refuses unvisited X1 candidates, including candidates
  in a later universal slice. Ambiguous instruction-shaped data is not rewritten
  or treated as proof of a complete conversion. Malformed images, unsupported
  instructions and incomplete SHA-256 coverage also fail before guest writes.
- Frameworks are re-sealed through the existing shared-link-safe sealing
  helper. If a write or re-seal fails, the prior executable, backup and resource
  seal bytes are restored. Failure of that restoration aborts installation;
  the caller must not publish a receipt claiming the prior state survived.
- Deselection restores `.bak`, removes it before re-sealing the bundle, and
  removes the live receipt entry. A previously recorded patch with no original
  backup remains live and is reported as not revertible.

An isolated library failure is reported by the existing guest-patch failure
summary; it is not added to the applied or not-applicable set. Other guest
patches can still run. `fw patches` therefore continues to report the missing
change. The standalone CLI also requires complete conversion for these names;
its existing boot and accessibility targets retain their prior behavior.

The shared-seal prerequisite matters: pristine `CodeResources` files can have
thousands of hard links. The inspected iOS 26.1 DebugHierarchyFoundation seal
had 5,344 links; on 26.6.2 it had 5,505 and shared its inode with GPUToolsCapture.
Upstream commit `df8d4a5c5268824db650c58526b3ec396b2e6de6` detaches those links
before codesign writes in place and can repair an earlier polluted shared seal
when the original executable proves its hash.

## Other releases and tools

Eight System-volume images from each of the following IPSWs were inspected:
introspection dispatch, BacktraceRecording, MainThreadChecker, RPAC,
ViewDebuggerSupport, DebugHierarchyFoundation, GPUToolsCapture and
GPUToolsDiagnostics.

| Userland | Device / build | Result |
| --- | --- | --- |
| iOS 26.1 | iPhone17,3 / `23B85` | All eight ordinary arm64e; no edits; byte-identical output |
| iOS 26.6.2 | iPhone18,1 / `23G90` | All eight ordinary arm64e; no edits; byte-identical output |

The iOS 26 cryptex libraries were not included in that audit. The declarations
use unrestricted version applicability because the instruction conversion
checks the actual image. The TV, HomePod, watchOS and visionOS presets keep the
new declarations off by default; their debug toolchains have not been validated.
An explicit selection still has to pass the same image checks.

Fifteen inspected DDI binaries (including XCTest, XCUIAutomation, Testing and
their support libraries), and Xcode 27.1's device ASan and UBSan runtimes,
contained ordinary arm64/arm64e slices. This inventory establishes no X1
conversion requirement for those files; it does not establish functional
support for every test, sanitizer or GPU debugging operation.

## Validation boundary

The regression tests exercise actual native signing, ordinary-image and
missing-file no-ops, identifier/entitlement preservation, repeat application,
deselection, failed bundle signing, failed reapplication and revert, missing
original backups, and atomic refusal of an incomplete universal conversion.
Catalogue tests cover independent selection on older, future and unreadable
versions, and unchanged opt-out behavior of unvalidated OS presets.

The patch-model, catalogue, X1 and signature suites passed (95 tests in the
initial full selection). After adding the rollback-abort regression, the final
installation and selection suites passed all 11 tests. `VPhoneCommand` also
built for the offline checks; that host build used the existing local
limera1n-removal overlay for the unrelated restore backend, not included here.

The failure was observed on a running guest. Subsequent app startup validation
on 2026-11-13 found a separate UIKit accessibility image missing from this
inventory. After the [accessibility additions](accessibility_library_x1.md),
both ordinary and LLDB startup passed with accessibility enabled, including
live instruction and backup verification. The full set of view, GPU, XCTest
and sanitizer workflows still needs guest validation. No Apple binaries,
application binaries or private crash captures are included in this contribution.
