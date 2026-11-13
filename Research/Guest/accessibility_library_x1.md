# Standalone accessibility plug-ins and X1 app startup

## Failure and coverage gap

On iOS 27.1 `24A94425` with cloudOS 26.4 `23E5207q`, a development app
stopped during UIKit accessibility initialization in
`+[AXUIKitPopGlue initialize]`, inside
`/System/Library/AccessibilityBundles/UIKitPopAccessibility.axbundle/UIKitPopAccessibility`.
LLDB reported `EXC_BAD_INSTRUCTION`, subcode `0xdac1a7fe` (`pacibsppc`).
The original watchdog report and the LLDB reproduction identify the same UUID,
`F922C0BE-2FC6-357A-9095-FF9831CD30A8`, and relative address `0xfd0`.
The function also contains `retabsppc`. These addresses identify the evidence;
the existing control-flow-based X1 planner finds the patch sites.

The M4 Pro host reports `hw.optional.arm.FEAT_PAuth_LR = 0`.
The app's crash-reporting machinery suspended threads after the instruction
fault, and scene creation then exceeded the ten-second watchdog deadline.
This explains why the final crash report names a watchdog, while the initial
failure under LLDB is an unsupported instruction in an Apple plug-in.

The guest receipt already contained the twelve standalone debug-library patches
and `system-homepopaccessibility-cfw-arm64e_x1`. Reapplying that existing
inventory alone cannot fix this failure: its HomePop entry
names `SpringBoardHomePopAccessibility`, not `UIKitPopAccessibility`.
The shared-cache converter cannot reach either standalone file.

## Inventory and implementation

Read each bundle's `CFBundleExecutable` and inspect the first 32 bytes of its
installed executable. Of the 517 entries in the AccessibilityBundles directory,
36 `.axbundle` plug-ins have standalone ARM64E_X1 Mach-O executables. The
existing HomePop patch covers one; `arm64eX1AccessibilityImages` declares the
other 35, including UIKit, SwiftUI, the Pop glue libraries, and the watch
companion plug-ins shipped in this iPhone userland. `BluetoothUIService` has
archive magic, not a loadable Mach-O, and is excluded. Separate `.axuiservice`
and `.bundle` service modules are outside this in-process `.axbundle` inventory.

The new inventory shares `CustomFirmwareArm64eX1Installation` with the debug
libraries. Declaration, CLI lookup and installation use the same paths.
Conversion must cover every X1 instruction candidate before a write can occur.
Original backups, entitlements, signing identifiers, shared bundle seals,
failure rollback and deselection retain that installer's existing behavior.
The new entries have image-based applicability: absent or ordinary arm64e images
keep their original bytes, signatures and inodes. Standard selects the entries;
TV, HomePod, HomeView, watchOS and visionOS presets do not opt into unvalidated ports.
HomePop retains its original ID and version gate for existing receipts.

This closes the measured in-process plug-in inventory, not an inventory of all
X1 images in the firmware. Do not use disabling accessibility, crash reporting
or debugger features as a substitute for validating the conversion.

## Validation

Private guest binaries and crash captures remain outside the repository.
The pristine UIKitPop image SHA-256 is
`38b17ce97790088c681e777c32d2b2f97f48392b1f965d064a90e860b143c76d`.
The regression suite covers the declared UIKit/SwiftUI paths, independent
selection, preset exclusions, and native signing, repeat application, revert
and failed sealing for both MH_DYLIB and MH_BUNDLE fixtures.

- 105 tests in 12 FirmwarePatcher suites passed, including all required patch
  model and catalogue suites. The VPhoneCommand scheme also built successfully.
- All 36 private originals converted with zero unvisited candidates: 3,168
  instructions and 122 re-attested slots. The 35 new entries account for 3,102
  instructions and 119 slots; HomePop contributes 66 instructions and 3 slots.
- UIKitPop converted 29 instructions in 2 slots; SwiftUIPop converted 45 in 2.
  Disassembly confirms the original fault site at `0xfd0` is now `pacibsp`,
  with the paired return at `0xff4` lowered to `retab`.
- Native Apple ad-hoc re-signing and `codesign --verify --strict` passed for
  every output. Entitlements matched the originals. A second conversion was
  byte-identical both before and after signing for every file.

## Guest validation (2026-11-13)

The complete `VPhone` scheme built successfully;
`codesign --verify --deep --strict` accepted the finished bundle.
The guest was stopped and snapshotted before `cfw update-environment` installed
the new patches. No restore was used. The update preserved the existing app
and data; the guest catalogue reported all 35 additions applied and zero
pending patches. This is a catalogue result, not a whole-system coverage claim.

The guest resumed under its original installed host VM runtime. Accessibility
automation was restored to its original enabled setting after reboot, with the
developer image mounted. An existing development app then passed both ordinary
and LLDB launches without rebuilding or replacing the app. The ordinary process stayed
alive and displayed its home page. The LLDB process remained running for more
than ten minutes; a manual interrupt found the main thread in its normal
CFRunLoop. The loaded UIKitPop image's actual instructions at relative offsets
`0xfd0` and `0xff4` were `pacibsp` and `retab` respectively. Accessibility
snapshot retrieval succeeded for that same process. The debugger
was detached and the app left running.

The live `.bak` was pulled and its SHA-256 matched the pristine UIKitPop hash
above exactly. This confirms the rollback source, in addition to the fixture
tests and isolated binary checks. This runtime validation covers app startup
and accessibility inspection, not every subsequent app feature or system service.

## Broader coverage audit

The new read-only command discovers native and universal X1 Mach-O files by
contents, independently of the patch catalogue and bundle/file names:

```zsh
vphone-cli cfw audit-arm64e-x1 /path/to/readonly/System-volume --json --strict > x1-audit.json
```

The argument is the volume root containing `System/`, `usr/` and `Applications/`,
including the installed physical OS cryptex; the command refuses a path without
`System/` and `usr/`, such as the `System/` subdirectory itself.
The default examines `MH_DYLIB` and `MH_BUNDLE`; `--include-executables` also selects `MH_EXECUTE` and
`MH_DYLINKER`. Symlinks, `.bak` files/directories, kernel extensions and dyld
shared caches are outside this scan. Shared caches need their separate converter;
an external cryptex or developer image needs a separate mounted-root audit.

Discovery uses confined, non-following directory/file descriptors. The existing
Capstone/control-flow planner and code-signature coverage checks run on private
memory copies; no image, signature, backup or receipt is written. Remaining
instructions, incomplete conversion, malformed load commands, signature errors
and traversal/read errors prevent a strict pass. An X1 header alone does not:
lowered images retain that header and are reported as `noLoweringNeeded`.
Five audit regression tests cover unknown filenames, native and universal
images, universal magic without an X1 entry (a Java class file), strict failure inputs, unchanged bytes/inodes/mtimes, inaccessible empty
APFS markers, and executable/kernel selection. They passed, as did the command
build. The complete `VPhone` bundle also rebuilt with this command and
passed deep, strict signature verification. A strict scan of all 36 converted
private accessibility images passed.

The pre-update snapshot of the same 27.1 System volume was mounted read-only
and scanned, including standalone files throughout the installed cryptex. The
complete report covers 252,612 regular files of at least 32 bytes, skips 35
backup entries, and finds 1,211 X1 library/bundle images. There were zero
traversal/read failures and zero failed image analyses. The full strict command
exited with status 1 because of the remaining and incomplete plans:

| Result on the pre-update snapshot | Images | Instructions planned | Unvisited candidates |
| --- | ---: | ---: | ---: |
| No lowering needed | 157 | 0 | 0 |
| Complete lowering plan available | 1,047 | 930,577 | 0 |
| Incomplete plan | 7 | 8,269 | 1,896 |

Of the 1,047 complete plans, 35 are the accessibility additions already deployed
and validated above (3,102 instructions). **The other 1,012 complete plans and
the seven incomplete images are outside this patch inventory.** Examples include
`MapsOfflineService.bundle`, `AccessibilitySettings.bundle`,
`PhoneCallFlowDelegatePlugin.bundle`, cryptex `Nodes.framework`, and standalone
`libobjcMsgSend*.dylib`. Their presence establishes remaining instruction
coverage work; it does not establish that each image is loaded by an ordinary app or that
each corresponding system feature has crashed. In particular, the inherited
exception translator can handle paths that a debugger or crash reporter may
intercept first.

The [remaining inventory](standalone_x1_remaining_24A94425.md) now annotates
cache relationships separately from lowering state. Comparison with all 4,702
installed cache images identifies four matching builds, one different-build
ASan variant, 15 message-send-family entries and 999 images without a matching
cache entry. The matching cache-extracted builds have no remaining X1
candidates; the standalone copies retain their original audit results. The
same report records 10 P1 conversion-validation candidates and eight P2
feature/service checks, with concrete dependencies or plug-in metadata and
explicit runtime-validation limits. These annotations do not select new patches.

The incomplete images must not be reported as clean or patched by a byte sweep:

| Image | Unvisited candidates |
| --- | ---: |
| `System/Cryptexes/OS/usr/lib/libramrod.dylib` | 1 |
| `System/DriverKit/usr/lib/system/libsystem_platform_debug.dylib` | 2 |
| `System/Library/SyncBundles/AirFair.syncBundle/AirFair` | 31 |
| `System/Library/SyncBundles/AirFair2.syncBundle/AirFair2` | 296 |
| `System/Library/SyncBundles/MusicLibrary.syncBundle/MusicLibrary` | 296 |
| `usr/lib/libCoreFP.dylib` | 163 |
| `usr/lib/libCoreKE.dylib` | 1,107 |

Those candidates require code/data and control-flow analysis before the planner
can claim full coverage. Even a complete plan alone does not validate native
signing, bundle seals, reapplication, rollback or runtime behavior for a newly
selected image.

Run this audit against every new userland/cryptex and before accepting broader
debugging coverage. Preserve the JSON with the firmware version and compare
paths and states between versions; a new filename must not silently inherit a
clean result from the current list. `--strict` supplies an explicit nonzero
gate for remaining/incomplete coverage. The command is available for validation;
it is not silently added to normal environment updates and does not auto-patch
unreviewed discoveries. The present firmware is expected to fail the full
strict audit until the remaining inventory is addressed.

The complete, grouped list of the remaining 1,019 images is recorded in
[Standalone X1 remaining inventory](standalone_x1_remaining_24A94425.md),
including each path, plan state, byte size, instruction/slot counts and
unvisited candidates. It contains no private app or workstation identifiers.

## Conversion cost

Three serial measurements on an M4 Pro, using fresh copies of the 35 original
accessibility images and the command-line converter and native signer, took
1.542, 1.360 and 1.306 seconds in total. Lowering plus code-slot re-attestation
took 0.827, 0.710 and 0.706 seconds; signing took 0.714, 0.650 and 0.600 seconds.
The measurements include command process startup but exclude copying the input,
volume mounting, bundle resource sealing and guest writes. They are not complete
environment-update timings and cannot be extrapolated by image count alone.
The 35 pristine files total 3,765,040 bytes; their backups are retained for
reversion. No runtime interpreter is introduced, and ordinary app installation
or launch does not repeat this conversion. Runtime performance was not benchmarked.

The current installer starts from the backup and repeats conversion and signing
on an environment update. A future cache would need to identify the original
bytes, converter/signing policy versions and installed output, while retaining
reversion and detecting changed bundle resources. No such cache is implemented
by this change.

The existing debug-library inventory alone was insufficient, and this addition fixes the observed
startup failure plus the measured `.axbundle` inventory. It does not claim that
all future standalone system-library X1 faults have been eliminated. Private
firmware, crash captures and full audit JSON remain outside the repository.
