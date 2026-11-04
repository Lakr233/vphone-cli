# tvOS support

## Apple TV 4K (4th generation)

Added on 2026-10-23: `AppleTV18,1`, board `J265AP` (`j265ap`), with **tvOS
27.2 only**. The supplied Pallas SoftwareUpdate response lists beta assets
`24K120` and `24K6120` pointing to the same AEA archive and key. Its actual
BuildManifest and SystemVersion both identify `27.2` / `24K120`, so the catalog
uses that build and offers one pairing. The archive is 5,234,491,392 bytes,
SHA-256 `a98cff4d0006b4c047c4eff163c5c1cb17fe0d1f67005ea575050523c7b858f7`.
The URL and public symmetric key are recorded in `VPhoneFirmwareCatalog`.

This board reuses the 3rd generation's OTA path: Apple TV HD 26.6 (`23L773`)
provides the restore base, cloudOS 26.4 beta (`23E5207q`) provides the boot
chain/kernel, and the OTA supplies J265's tree and System userland. The virtual
canvas is 3840×2160 at 2x. Its payload chunks use `pbzm` / LZRAVEN, so creation
requires macOS 27. On an older host there is no catalog pairing for this model;
it cannot fall back to tvOS 26.6. OTA identity checks reject OS versions other
than 27.2, including renamed local archives.

Both `vm create` and Launchpad New Machine use the existing `tvos-4k` preset
and a standalone restore without template slimming:

```zsh
vphone-cli vm create tv4k4 --device AppleTV18,1 --cpu 4 --memory 4096 --disk-size 48
```

Use Launchpad and VPhone.bundle **2.13** together. Earlier Launchpad versions
would choose the HD preset for this new product type. The CLI/catalog schema
is unchanged; the new series keeps that preset decision paired with the new
device catalog. Firmware patch discovery now preserves any recorded OTA board
with a restore base, so the HD manifest cannot replace J265's guest identity.
The current `tvos-4k` preset retains the new 27.2 Setup app and selects its
SetupBackground display lookup repair. The legacy TVSetup fallback used in
the earlier validation below is now off in every preset. The new setup's
input issue remains under investigation; see [native Setup and remote
panel](#native-setup-and-remote-panel). There is no new instruction patch or preset.

Validation completed without admin privileges:

- Xcode builds of `VPhone.bundle` and Launchpad; core identity/catalog tests,
  all 113 archive tests, 116 selected firmware/device-tree tests, and 32 patch
  model tests passed. Two TCP timing tests failed in the full core run and
  passed when rerun individually. Launchpad product/catalog and bundle-version
  tests passed.
- `fw prepare` against the real OTA and cached base/cloudOS IPSWs decrypted
  the archive, verified `27.2` / `24K120`, staged `DeviceTree.j265ap.im4p` and
  all **42** payload chunks, reused the cached GPU driver, and recorded
  `AppleTV18,1` in `config.plist`.
- `fw patch` with `tvos-4k` processed all **11** components and applied **239**
  patches. The patched device tree reports model `AppleTV18,1`, target `J265`,
  and subtype `J265AP`. No undeclared-patch warnings appeared.
- Selective, unprivileged extraction confirmed dyld and launchd are arm64e
  `USR00`, and SystemVersion reports `27.2` / `24K120`. Dry runs of the five
  enabled tvOS 27 cache patchers succeeded: IOMFB found 10 trampolines, lsd and
  libxpc found their gates, maxSlide needed no change because the cache fits,
  and lockdown mode had no target. The cache-loader gate patch also succeeded
  on a separate extracted copy.

Live validation on 2026-10-24 used the persistent machine
`~/.vphone/machines/tv4k4`, cloned from the prepared scratch machine. Launchpad
2.13 and its helper installed and admitted the local bundle. The native restore
completed for ECID `0xF853D2724C37EC35`; full `cfw install --keep-artifacts`
then applied 109 patches and installed all 42 OTA chunks. The machine is bound
to local bundle `2.13.0-local.aaf2152c`. Other machines were left stopped.

The installer now promotes the installed OTA's SystemVersion for TV as well
as HomePod, after the private disk clone is committed. Without this, the host
kept showing the HD restore base's 26.6 even though the guest ran 27.2.
`RestoreInfoTests` passed all 21 cases after the change, including both 4K
identities, and the finished bundle rebuilt successfully.

Both normal boots reached vphoned in about five seconds. `device.info` reports
`AppleTV18,1`, `27.2.0`, four CPUs, 4 GB, and a 1920×1080-point screen at 2x.
Graphical startup initially stalled: the native window retained the boot logo,
and guest screenshots were black. SetupBackground's scene-create watchdog
found its main thread in `PBSDisplayManager._init`, waiting on a semaphore for
`fetchCurrentDisplayStateWithReply:`. Static analysis confirms a 15-second
client wait against the scene's 10-second watchdog; the server implementation
dispatches to the main queue and replies with its serialized state without a
display-mode readiness gate. A missing client proxy can also produce that
wait, so this stack alone did not establish the failure's cause.

One controlled restart of `com.apple.PineBoard` allowed SetupBackground's
scene to become ready, and the new Setup app rendered its animated Hello
screen at 3840×2160. A third cold boot stalled again; restarting Setup alone
did not recover it, and a second PineBoard restart did not reliably help.
Keyboard Return through vphoned, the host API and the native window did not
advance the recovered Hello screen.

A temporary native probe then isolated the sandbox lookup. As `mobile`, the
display service returned real 3840×2160 display state immediately, and
`PBSDisplayManager.sharedInstance` initialized on the main thread in 0.006 s.
Signing the same probe with SetupBackground's original three entitlements
(application identifier, platform bit and container requirement) changed that
to 15.049 s. Adding only
`com.apple.security.exception.mach-lookup.global-name = [com.apple.PineBoardServices]`
reduced it to 0.005 s. The container requirement remained on. This reproduces
the scene watchdog without involving video playback or the GPU.

`system-setupbackground-exp-pineboard_lookup` adds that single exception,
preserving the app's other entitlements. The declaration applies only to
27.2, is opt-in, and the installer rejects a non-TV identity.
It saves the original executable as `.bak`, allowing the normal guest patch
selection and `cfw update-environment` to reverse it. All 55 focused patch
catalog, guest resolution and entitlement tests passed, as did the 32 patch
model tests; the finished bundle rebuilt successfully. After administrator
authorization, Launchpad installed `2.13.0-local.ea3237b6`, and
`vm set-bundle tv4k4 2.13.0-local.ea3237b6 --update-environment` applied the
patch. The guest receipt records it live. The installed executable has exactly
the original three keys plus the single lookup array; its `.bak` is byte
identical to the original pulled before the update.

The first patched cold boot reached vphoned in five seconds and the animated
4K Hello screen without a PineBoard restart. PineBoard, backboardd, Setup and
SetupBackground retain their startup PIDs; no crash report was present after
the boot. Consumer-page Select (`0x0C/0x41`) still did not advance Hello. A
12-second Setup log capture around a press contained 144 normal rendering
entries but no `Remote pressed.` handler entry. Static analysis and Swift
field metadata show this handler checks `_hasDrawingStarted` and
`ScenePhase.active`, not a mandatory paired-Bluetooth-remote condition. The
unresolved cause is event delivery or these local scene gates.

PineBoard retains a native fallback: `CompanionServices/TVSetupV2`, or
`TVSetupV2HW` plus its product-type gate, selects `com.apple.Setup`; with both
flags disabled it selects `com.apple.purplebuddy` (TVSetup). This TVSetup is
from the 27.2 OTA (its SDK and minimum OS version are 27.2), not the HD restore
base. A temporary Data-volume override of both flags followed by a cold boot
opened its 4K Language screen. Consumer Down/Up and native-window keyboard
Down/Up moved English to Simplified Chinese and back without selecting a
language. REA evidence: `ev_e11258e9f22e339e9c8e1eedd8108024a7a9859b12a8c4cb966954461712f258`
and `ev_be3a9edd8bf4e9ede9361aaa789b4cc9a4e282387021eb2ed7ca9f9fec6dd74a`.

The supported preset therefore uses `system-tv-exp-legacy_setup`, gated to
27.2 and selected only by `tvos-4k`. It sets `TVSetupV2.Enabled` and
`TVSetupV2HW.Enabled` to false in the System CompanionServices feature plist,
preserving other flags, metadata and encoding. The installer requires a TV
identity and backs up the original plist for reversal. It does not mark setup
complete or choose any setup options. The SetupBackground lookup repair now
remains opt-in for investigation of the new setup flow. The 59 focused
feature-plist, guest-resolution, catalogue and entitlement tests passed.

Launchpad installed final bundle `2.13.0-local.aaf2152c` and updated the guest
environment. Its receipt records the legacy setup patch and no display-lookup
patch. The System feature plist matches the offline patch output; its `.bak`
is byte-identical to the original. SetupBackground reverted byte-identically
to the original executable. The temporary Data override was removed before
boot and its absence confirmed from the guest.

The final bundle's first cold boot reached vphoned in six seconds and the 4K
Language screen. Consumer Down/Up moved English to Simplified Chinese and
back. Native keyboard Return opened Region, and Escape returned to Language.
No region, permissions, agreements, accounts or setup completion were chosen.
The initial host window, tested after clearing only this machine's saved frame,
has exactly 3840×2160 content plus the 104-pixel toolbar and correctly labels
tvOS 27.2.0. Window fitting now follows toolbar installation and showing the
window so AppKit's initial screen constraint cannot distort the wide panel.
PineBoard (38), backboardd (74) and TVSetup (214) retained their PIDs over the
first minute; the crash list remained empty. A second final cold boot reached
vphoned in five seconds and rendered the 4K Language screen again, with no
crash reports. The VM is left running there. `ui.tree` cannot verify the frontmost app on TV, so input
verification uses direct screenshots and the native VM window.
Logs, the watchdog report, a guest spindump and screenshots are retained under
`/private/tmp/vphone-appletv18-*` and `.build/appletv18-validation/`.

## Native Setup and remote panel

Current source, 2026-10-24: `tvos-4k` blocks
`system-tv-exp-legacy_setup` and enables the existing 27.2
`system-setupbackground-exp-pineboard_lookup` and
`system-setup-exp-deferred_focus`. An environment update restores
the original CompanionServices feature flags from their `.bak`, then applies
the single display-service lookup entitlement repair and the native button-
focus policy adapter in Setup. This returns an earlier
test VM to `com.apple.Setup`, without changing setup completion or choices.
The current bundle is `2.13.0-local.9ffd2d6e`. Its installed focus adapter
passes cold-boot input testing, and native manual setup advances past activation.

The new panel is available only for Apple TV guests under **Device > Apple TV
Remote** (Option-Command-R). Its silver remote face has a directional clickpad
and Select, Back, TV/Control Center, Play/Pause, Mute, volume rocker, side Siri
and Power buttons. Native buttons expose accessibility labels and keyboard
focus. Click/hold sends distinct consumer HID down/up events, so the guest can
interpret taps, multiple clicks and holds. Closing, minimizing, losing focus
or disconnecting releases held controls; a failed release is retried before
new input on reconnection. A cancelled queued press cannot reach a later
connection. Remote controls are disabled while the agent is unavailable.

Arrow keys, Return and Escape in the panel send the remote's directional,
Select and Menu events. Space activates a focused button, or Play/Pause when
the remote face has focus. H, M, +/-, S and P map to TV, Mute, Volume, Siri and
Power. The HID consumer MenuEscape usage (`0x46`) is Back; ACBack (`0x224`)
is a different UIKit press type. These mappings are verified against the
matching tvOS 27.2 UIKitCore, rather than inferred from keyboard behavior.
The control layout and hold semantics follow Apple's
[Siri Remote guide](https://support.apple.com/en-us/102337).

Offline validation uses `Tests/run-tv-remote-tests.sh`, a host-only AppKit
harness with no guest connection. It exercises all 13 accessible buttons,
directional hit areas, pointer holds, overlapping keyboard/pointer sources,
modifier-safe releases, cancellation while the shared queue is suspended,
and release recovery after disconnection. Completed AX/button taps survive
panel key loss, unfinished holds are cancelled before releasing the view, and
a connection epoch keeps old taps out of a later guest. The harness exercises
the actual AX button through that cancellation sequence. It renders the native
view to a PNG for visual review. The focused patch suites pass 63 tests and
the patch model suites pass 32. The finished bundle builds and passes bundle
admission. Live remote tests passed Home/Settings navigation, Select, Back and
a held TV button opening Control Center. The new focus/preset checks passed
54 focused tests; the activation declaration's version/preset matrix then passed
49 selected tests. Installed cold-boot focus and completed-tap delivery pass:
Hello appeared at 21:23:00 UTC, and the first actual remote AX Select after
more than 65 seconds idle advanced to Quick Start at 21:24:19. No directional
input, RPC priming, or debugger was used. Siri/audio integration remains outside
that validation.

Live inspection localized Hello's failure to native deferred focus. Select
reaches the active key window as UIPress type 4 with window suppression off,
but no item is focused. UIKit already holds Hello's preferred item as a
deferred target. A normal Up commits it and the next Select enters Language;
the native deferred-focus method also commits it without an arrow. Initial
focus-operation prototypes expired after the native 60-second idle timeout.
The final adapter instead uses native TV button-focus policy (`0`) only for
an active key Setup window with WaffleIron/default-3/nil-override state;
explicit unrelated overrides are preserved. Native preferred focus and
eligibility still choose the item. Scene/key/focus notifications recheck
asynchronously, with no swizzles or polling. A manual policy-0 trial retained
focus beyond 80 seconds, and ordinary Select advanced English to the country
picker, then United States to Quick Start. [The investigation](tvos_27_setup_input.md)
records the exact boundaries and installed test. No pairing,
drawing, scene-phase or setup-completion state is fabricated, and no Hello
command or readiness check is bypassed.

The exact built focus adapter was then loaded into a fresh native Setup
process without a manual policy call. It initialized native focus and ordinary
remote input advanced Quick Start to Set Up Manually. Activation failed with
`NSOSStatusErrorDomain` -71136. The matching tvOS mobileactivationd retains
the same local-activation path as the existing iPhone patch; its getter was
unpatched because TV excluded it. `system-mobileactivationd-exp-tv_activation`
now reuses that patch under an exact 27.2 gate, selected only by `tvos-4k` and
admitted only for arm64e Apple TV. Older TV releases and HomePod keep their
existing selection. The complete bundle builds and 49 focused tests pass.
After administrator authorization, cold boot of `a4b9ffc4` exposed a sealing
bug: final bundle signing dropped Setup's original entitlements and caused
TCC Bluetooth usage-description crashes before Hello. `da14d7a4` preserves
those entitlements during both application and reversal of the focus adapter.
The actual installed executable's full entitlements compare byte-identically
to pristine Setup. Its signature verifies with the pulled Info.plist and
CodeResources (resource contents excluded from that host check). Both new
patches are recorded applied, with zero pending patches and legacy setup off.
The corrected cold boot reaches Hello; the actual remote's Manual selection
advances through activation to room choice, Data & Privacy, and Terms &
Conditions. After the user's action-time confirmation, Terms were accepted,
account sign-in was skipped, and optional Siri, location, and analytics were
declined. Native Welcome then advanced to the Home Screen. Native preferences
now contain SetupDone=true, TVBuddyCompletedSuccessfully=true, and
TVSetupVersion=15; Setup itself wrote these completion values and exited.
English/United States and America/Sao_Paulo were preserved; Office was chosen
only on the diagnostic clone. The original VM was also updated to `da14d7a4`,
cold-booted in five seconds, and retained its prior completed setup and data.

Final original-VM remote tests pass navigation, Select/Back, Control Center,
Siri search/dictation UI, Power hold to sleep and TV to wake. Volume Up/Down,
Mute (twice), and Play/Pause were exercised without active media; audible
effects remain unverified. All inputs were released and Home restored. The
two unused builds with the sealing defect (`8e456731`, `a4b9ffc4`) were removed.

Completion exposed an additional read-only reporting bug: vphoned compared the
absent iOS SetupVersion against BYBuddyIOSCurrentVersion even on Apple TV.
`9ffd2d6e` uses TVSetupVersion, dynamic BYBuddyTVOSCurrentVersion, SetupDone,
and TVBuddyCompletedSuccessfully for runtime Apple TV models. iPhone/HomePod
and the existing skip operation retain their previous behavior. No completion
state is written. The full bundle builds and its 376-check logic harness passes.
After administrator installation, both machines' guest environments match
`9ffd2d6e`. Each cold boot answers vphoned in five seconds and reports native
setup/current version 15, SetupDone=true, pending=false, and no Setup process.
The clone returns directly to Home without running Setup again and is then
stopped. The original VM remains running with its data and completed setup
preserved. Both patch receipts have zero pending changes and legacy setup off.
The final original-VM Home capture and actual remote Back/Right test also pass;
all 13 controls are enabled and the VM is left at Home with input released.

## Earlier Apple TV validation

Validated on 2026-10-15: AppleTV5,3 tvOS 26.4 beta 1 (23L5208m) on the
cloudOS 26.4 beta (23E5207q) vphone600ap platform boots to TVSetup and Settings.
The same VM booted normally with four CPUs after installing the persistent
kernel fix, without a debugger. Arrow keys, Return and Escape navigation were
confirmed by the user. Device > Back sends the same native Escape key pair;
that menu action has not been separately confirmed.

Validation covers the specific donor/kernel pairing listed below. Settings >
About reports tvOS 26.4 (23L5208m), an IPv4 address, and 1080p HD / 120 Hz.
The display mode is reported metadata, not measured rendering performance.
Activation reports Failed and the model is Not Applicable. Apple services,
audio, video playback, third-party apps and long-term stability remain untested.

Later the same day: tvOS 26.6 (23L773), the last release for the Apple TV HD,
restored on the same cloudOS and booted to TVSetup with vphoned running. The
guests now run vphoned (see [vphoned on tvOS](#vphoned-on-tvos)), which gives
the TV button: Home on a press, Control Center when held. The firmware catalog
lists tvOS 26.6 for the Apple TV HD, and New Machine and `vm create --device
AppleTV5,3` build it with the `tvos` preset.

tvOS 27 dropped the Apple TV HD, and Apple publishes no IPSW for any Apple TV
4K. The 3rd generation (AppleTV14,1) and 4th generation (AppleTV18,1) use
full OTAs. An Apple TV 4K guest is the HD's
26.6 restore with the 4K's identity and arm64e userland taken from its OTA;
`fw prepare` reads the OTA itself. See
[Apple TV 4K from its OTA](#apple-tv-4k-from-its-ota).

## Firmware and storage

- Donor: Apple TV HD, `AppleTV5,3`, board `j42dap`, plain arm64 / TVOS.
- Kernel, boot chain and SEP: cloudOS 26.4 beta, `vphone600ap`.
- [Apple-hosted donor IPSW](https://updates.cdn-apple.com/2026WinterSeed/fullrestores/089-95491/1679DEB6-820D-40A8-9F28-1735EFDFB01D/AppleTV5,3_26.4_23L5208m_Restore.ipsw).
- Verified SHA-256: `2128c348ffbb0f65096ac3e7be22e901e09773e02c17edbce4c0647769c24ae8`;
  length 5,269,316,627 bytes.
- [tvOS 26.6 IPSW](https://updates.cdn-apple.com/2026SummerFCS/fullrestores/140-67287/F525C1FF-B49B-40AB-A5F4-A6F4A4847407/AppleTV5,3_26.6_23L773_Restore.ipsw),
  the catalog's pairing. SHA-256
  `a5f3e397ba4d8cd03c6c46709b3d8f9811af58a5a2e758e2334317fbc68db292`, as AppleDB
  records it; length 5,269,471,026 bytes.
- The lab reuses one logical 32 GB disk, about 11 GiB allocated. No second
  VM, template, or automatic PCC GPU recovery disk was created.

The matching release numbers motivated the pairing investigation; they do not establish
compatibility with other builds. Every TV pairing uses cloudOS 26.4: the kernel
fix below exists only for its kernel. The beta archive, FirmwareOriginals and
restore tree are retained locally for reproducibility and rollback.

## Creating an Apple TV machine

In Launchpad, New Machine > Device > Apple TV HD. The sheet picks tvOS 26.6
and the `tvos` preset, and turns Use Template and Slim System off: both drive
iOS Setup Assistant and its apps. From the command line:

```zsh
vphone-launchpad-cli vm create tv --device AppleTV5,3 --cpu 4 --memory 4096 --disk-size 32
```

The machine is restored on its own and starts at TVSetup. Navigate with the
arrow keys and Return; Escape goes back, holding it returns to the Home
screen. The titlebar Home button and the Mac's Home key (fn-←) are the TV
button: a click or press goes Home, holding either opens Control Center.
Device > Home Screen (⌘⇧H) and Device > Control Center (⌘⇧T) do the same
through vphoned.

## Reproducing the validated configuration

Use the built bundle's `vphone-cli` on a host configured according to
[host setup](../../Documents/en/get-started/host-setup.md). Both IPSWs must be supplied
locally: a donor above and cloudOS 23E5207q. Other pairings are unvalidated.
The VM and the installer's temporary directory must share an APFS volume;
TV guest updates refuse an in-place fallback when cloning is unavailable.
Copy-on-write updates share unchanged blocks, but require space for changed data.

For a **new** VM only, run these commands in zsh, replacing the three paths.
Do not run `vm new` or restore against an existing VM you want to preserve.
This manual pipeline creates one 32 GB disk and no template, as `vm create
--device AppleTV5,3` does. The historical `--iphone-source` option accepts the
TV donor.

```zsh
cli='/absolute/path/to/VPhone.bundle/Contents/MacOS/vphone-cli'
tv_ipsw='/absolute/path/to/AppleTV5,3_26.4_23L5208m_Restore.ipsw'
cloud_ipsw='/absolute/path/to/cloudOS_23E5207q_Restore.ipsw'
export VPHONE_LIBRARY_ROOT="$HOME/vphone-tvos"
vm='tvos-26_4-beta'
"$cli" vm new "$vm" --cpu 4 --memory 4096 --disk-size 32
"$cli" fw set-patches "$vm" --preset tvos
"$cli" fw prepare "$vm" --device AppleTV5,3 \
  --iphone-source "$tv_ipsw" --cloudos-source "$cloud_ipsw"
"$cli" fw patch "$vm"
"$cli" vm launch "$vm" --dfu
```

Leave DFU running. In a second terminal, set the same `cli`, `vm` and
`VPHONE_LIBRARY_ROOT` variables, then run:

```zsh
"$cli" restore "$vm"
"$cli" vm stop "$vm"
sudo "$cli" cfw install --library-root "$VPHONE_LIBRARY_ROOT" "$vm" --keep-artifacts
"$cli" vm launch "$vm"
```

If host preflight refuses the VM binary, run its printed allowlist command and
retry the launch. Navigate setup with arrows and Return; Escape goes back.
`vphone-cli vm wait`, or `vphone-launchpad-cli vm wait`, reports when vphoned
answers.

`fw set-patches` replaces all overrides; the `tvos` preset holds the whole
Apple TV selection. On an installed, stopped VM, guest-side changes use `sudo "$cli" cfw
update-environment --library-root "$VPHONE_LIBRARY_ROOT" "$vm"`; kernel changes
use `sudo "$cli" cfw update-kernel --library-root "$VPHONE_LIBRARY_ROOT" "$vm"`.
Neither requires another restore. A prior research installation must first
remove its diagnostic jobs with the preserved research bundle; the PR bundle
does not contain those removed patch implementations.

## Required implementation

1. Admit AppleTV5,3 explicitly. Copy its TV idiom, identity, 1x artwork and
   `app-macho-architecture=arm64` from the donor device tree. The virtual display
   uses 1920x1080; 72 ppi is a provisional VM value, not television metadata.
   Preserve the virtual identity in the restore tree. Non-iPhone restore-tree
   names retain the existing `iPhoneOS_…_Restore` compatibility prefix.
2. Admit the monolithic TV filesystem only after validating its erase identity,
   TVOS platform and required component paths. It contains neither OS nor App
   cryptex; its cache remains at `System/Library/Caches/com.apple.dyld` and uses
   architecture `arm64`. Other guest families keep their cryptex layout.
3. Rehash the unchanged TV `OS`, `SystemVolume`, `StaticTrustCache` and
   `Ap,SystemVolumeCanonicalMetadata` with SHA-384 in the hybrid manifest.
   J42d's SHA-1 donor digests failed PCC metadata authentication and sealing;
   the corrected hybrid restore completed.
4. Apply the existing seputil/gigalocker repair, vphoned and the launchd
   cache gate its job needs. Block unvalidated iOS guest payloads,
   graphics/audio hooks and shared-cache patches; the `tvos` preset does both.
   Preparation skips the GPU driver for an Apple TV, avoiding an unnecessary
   recovery VM whatever order the selection is recorded in.
5. Enable `system-dyld-exp-tv_tpro` and `kernel-exp-tv_tpro_pagers`. Both
   are off in Standard and on in `tvos`, and apply to every tvOS 26 userland
   on cloudOS 26.4. Keep the donor's
   native shared cache and page-in linking intact.
6. Forward Escape to the TV's native virtual keyboard instead of consuming
   it as an iPhone edge swipe. Device > Back uses the same keyboard path,
   without vphoned. Backspace remains available for editing text. Home and
   Control Center go through vphoned (below).

The dyld operation rewrites only the exact `dyld_hw_tpro` and
`dyld_hw_tpro_pagers` parameter-name prefixes to `vphn`, in both standalone
and cached dyld. It validates TVOS/arm64, symbol bounds, getenv references and
presence checks, then re-attests the modified code-signature slots. A backup
and shared-cache undo record support paired rollback. An existing patch must
have both records before another write. Paired failures abort the install and
discard its private disk clone; rollback retires undo only after both images
are restored.

## Kernel cause and persistent fix

The embedded research kernel UUID was
`784F88D3-2AF5-3D4A-AB00-365607646E44`. Native runtime tracing caught
MobileGestaltHelper, UUID `7CF0ED37-E30C-38AA-AE6C-F10A7CA15BC8`, at a libobjc
store with ESR `0x9200004f` and unslid FAR `0x1ea57c808`. Its DATA_CONST
RW|COPY request (`0x13`, size `0xa23c000`) returned KERN_PROTECTION_FAILURE.
Following the remap/extract calls showed a TPRO-tagged map entry while dyld
used an ordinary writable request. The source entry allowed maximum RW.
The local symbol dataset was unavailable; function descriptions were derived
from native control flow and correlated with XNU, not claimed symbol lookups.

The native `sprr_tpro_pagers` tunable controls tagging these ranges. Setting
its live value from 1 to 0 made subsequent COPY requests succeed and allowed
TVSetup to appear. No other functional debugger write was made.

The persistent patch changes only the integer tunable's initial four bytes.
It locates the unique NUL-terminated name, validates the four-byte integer
startup descriptor and its data pointer, and requires one TUNABLES registration
with an executable initializer. It accepts only defaults 0 or 1. Both segment
bounds and actual file bounds are checked. The fileset's outer `__DATA` contains
the embedded `__KLDDATA`. No observed offsets or instruction words are baked
into the patch; unsupported or ambiguous layouts fail the selected operation.
The tunable lives in the cloudOS 26.4 kernel, whatever tvOS userland it runs,
so the patch applies to every tvOS 26 donor on that kernel. tvOS 26.6 (23L773)
needed the same fix and booted with it.

`cfw update-kernel` rebuilt from FirmwareOriginals and replaced only the
installed Preboot kernel payload, retaining the manifest and volumes. A normal
four-CPU boot subsequently reached the Language screen, and the user navigated
to Settings > About. Disabling the kernel patch and running the same command
rebuilds from pristine bytes; the dyld operation is separately reversible.

## Validation and PR scope

The trimmed PR passed:

- 89 tests in seven firmware suites, including the real research kernel's
  exact four-byte change, blocked-gate byte identity and malformed/truncated
  tunable descriptor rejection.
- 36 final follow-up tests in four suites covering TV guest patch admission,
  TV dyld, patch declarations,
  missing-backup rejection and injected rollback failures. These overlap
  the preceding firmware suites and are not an additional unique-test count.
- 17 core identity/catalog tests, 15 archive admission tests, and the
  Launchpad IPSW classification tests.
- The final complete VPhone bundle build and bundle admission checks.
- A normal four-CPU, 4 GiB boot after removing the diagnostic patches. The
  user confirmed the UI works and Escape goes back. Device > Back uses the
  same key path but has not been separately confirmed.

The PR excludes diagnostic executables, launchd logging/cache modifications,
the abandoned page-in-linking fallback and the unused conclave change.
The lab's guest receipt after cleanup contains only TV dyld TPRO and the two
seputil/gigalocker repairs. TV environment updates recognize the guest receipt
when vphoned is omitted. Unreadable cache undo logs abort instead of being
silently replaced.

Native arrow, Return and Escape input does not require vphoned; the titlebar
Home button and Control Center do, and work now that the guest runs it.
Activation, model metadata, audio and Apple services retain the limitations
listed above; this validation does not establish full Apple TV compatibility.

Research helpers and the prior bundle are retained locally under
`.build/tvos-research/pr-backup`, outside the PR. Boot evidence is in
`.build/tvos-research/pr-clean-boot.log`; the Settings screenshot and earlier
native runtime transcripts remain beside it. No second VM disk was created.

## vphoned on tvOS

vphoned is an arm64 Mach-O, so the plain-arm64 TV userland can run it, and
every symbol it imports resolves in the tvOS 26.4 shared cache, UIPasteboard
and UIScreen included. Installed unchanged, it never started: each launch
left a crash report, `Library not loaded: …/Foundation.framework/Foundation …
(wrong platform to load into process)`. dyld takes the process platform from
the main executable, and vphoned's `LC_BUILD_VERSION` says iOS (2) while every
library in the cache says tvOS (3).

The bundle build now ships `guest-resources/vphoned-tvos`: the same binary
with `vtool -set-build-version tvos 15.0 <sdk> -replace`, signed with
vphoned's entitlements. `ValidateBundle.sh` requires it to be TVOS and every
other guest binary to be IOS. `cfw install` installs it for an Apple TV guest,
and launch stages it as `.vphoned.signed`, so the host's hash check keeps the
TV copy current instead of replacing it with the iOS one.

Its launchd job goes into `/System/Library/xpc/launchd.plist` as on iOS. The
`launchd_cache_loader` gate patch found and NOPed the same branch in the
plain-arm64 loader (`0xB00` in 23L5208m), and the console then shows `Using
unsecure cache: /System/Library/xpc/launchd.plist`. Both are now admitted for
TV (`FirmwareGuestPatchResolution.tvSupportedGuestPatches`). The environment
hooks (`system-launchdaemons-boot-environment`) stay blocked on the plain-arm64
HD; an arm64e TV admits a two-library port of them, see "RootHide bootstrap"
below.

Verified on 23L5208m and 23L773: `vm wait` returns, `device.info` reports
`own_name` "Apple TV", screenshots and `apps.launch` work, and consumer-page
HID input moves the TVSetup focus.

A TV guest has no shell, no package manager, and the `tvos` preset admits
neither debugserver nor any Frida patch, so the scripting session is the
debugging environment there: `script.eval` and the `/v1/shell` WebSocket run
JavaScript with vphoned's identity inside the guest. JavaScriptCore is a
public tvOS framework and the tvOS SDK ships its stub, so nothing has to be
installed. See "Scripting sessions" in `Research/vphoned_http_api.md`.

Nothing about the session needed a tvOS build: the tvOS SDK marks
`posix_spawn`, `execv` and the rest of the process API `__TVOS_PROHIBITED`,
but `vphoned-tvos` is the iOS build with its platform retagged, so those
declarations are never consulted, and the proxy has been spawning its worker
that way on TV guests all along. Compiling the daemon against the tvOS SDK
would fail on them; do not try to, and do not guard the session's code for
tvOS availability.

## RootHide bootstrap

Irisin 5.0.1 ships a third package, `appletvos-arm64e`, beside iOS's two:
`irisind`, `irisin-install` and the daemon's plist, tvOS 17 binaries (plain
arm64, platform TVOS), and no app. Irisin serves an Apple TV only as RootHide
and refuses any other root (its `Documentation/AppleTV.md`). OwnGoal's
repository carries no tvOS bootstrap package yet, so on TV the bootstrap is
the RootHide root, vphoned's base in it, and Irisin's privileged layer.

`bootstrap.install` decides the package by the platform dyld runs vphoned as
(`GuestBootstrapPlatform`: the main image's `LC_BUILD_VERSION`, TVOS for
`vphoned-tvos`), not by product type, so the HD and the 4K take the same
package. On tvOS `rootless` is refused before a root is created. The
package's missing app is allowed only for `appletvos-*`; vphoned then creates
no data directory, registers nothing and loads the daemon, which is what the
package's own postinst does. Every root also gets an empty `Applications`,
which icli's refresh needs to exist. The Apps menu offers only roothide on
an Apple TV.

Validation, 2026-10-26, `tv4k` on jp-01 (AppleTV14,1, tvOS 26.6 arm64e OTA
userland: `/sbin/launchd` cpusubtype `0x80000002`, `dyld_shared_cache_arm64e`),
the new `vphoned-tvos` delivered by the host's update path:

- `{"layout":"rootless"}` answers `Irisin serves only a roothide bootstrap on
  tvOS`; no `/var/jb` appears.
- `{"layout":"roothide"}` downloads `wiki.qaq.irisin_5.0.1_appletvos-arm64e.deb`
  (digest checked) and returns `architecture` `appletvos-arm64e`,
  `registration` null, `firmware_version` 26.6.0, `irisind` loaded, started and
  running. The base created `/tmp`, `/var`, `/var/root`, `/etc`, `/var/tmp`,
  `/dev`, `/rootfs` and the three account files from tvOS's own; `pwd.db`
  waits for a `pwd_mkdb` no tvOS package provides yet. The `.jbroot` loader
  links are in the root, `usr/lib` and `usr/libexec`.
- Irisin's tvOS test client (`irisin-external-probe`, root-owned in the
  root's `usr/libexec`, from Irisin's Apple TV test kit) gets `serviceInfo`
  with `installRoot` the vphoned root, installs and removes an `all` package
  (dpkg status lists it beside `firmware`, then only `firmware`), and is
  refused an `iphoneos-arm64e` package.
- After `system.reboot`, `bootstrap.inspect` reports the roothide root,
  vphoned's startup reloads `wiki.qaq.irisind`, and the daemon starts on demand
  for the client.

### Environment hooks

The iOS environment inserts SystemHook into every process and five more
libraries into named iOS processes (SpringBoard, Settings, installd,
lockdownd, cryptexd, configd). An Apple TV takes
`VPhoneGuestEnvironment.tvLibraries` alone, `launchdhook-vphone.dylib` and
`SystemHook-vphone.dylib`: the RootHide loader links and `VPHONE_JB_ROOT` at
each spawn, jetsam limits for bootstrap programs, and ElleKit's TweakLoader
when a bootstrap provides one. The spawn hooks insert a library only when it
is installed, so the others are simply absent. Both libraries are built for
iOS; `cfw install` and `cfw update-environment` mark them tvOS with
`MachOBuildPlatform` and sign them again, as the HomePod virtio sound driver
is. They are always written with `/vh` on TV, and removed with `/vh` when the
patch is off. The hook is loaded by `/vh`, the load command
`system-launchd-boot-jetsam_panic_guard_bypass` adds to launchd, so both
patches are admitted together, for an arm64e TV only: both libraries are
arm64e. Neither is on in `tvos-4k`; turn them on with `fw set-patches <vm>
--allow system-launchdaemons-boot-environment --allow
system-launchd-boot-jetsam_panic_guard_bypass`, then `cfw update-environment`.

Offline, on a copy of `tv4k`'s `/sbin/launchd` (586496 bytes): the jetsam
patcher found `jetsam property category`, function at `0xDA34`, and rewrote
`tbnz w0, #0, 0xdac4` at `0xDA68` to `b 0xdac4`; `inject-dylib` added
`LC_LOAD_WEAK_DYLIB /vh`.

Live, the same day on `tv4k`, with the RootHide bootstrap above installed:
`fw set-patches tv4k --allow …` for both, then `cfw update-environment`
logged `Environment hooks retargeted to tvOS`, the jetsam patch at `0xDA68`
and `/vh`. The guest booted to vphoned in 20 seconds and to the home screen.
The launchd hook inserted SystemHook into xpcproxy (203 spawns by then),
PineBoard, PosterBoard and the TV apps; SystemHook's log names
`root=/private/var/containers/Bundle/Application/.jbroot-000114514191980C` in
every process, so the hook found the vphoned root. The test client's request
started `irisind` through xpcproxy (`label=wiki.qaq.irisind`); the hook
checked its loader link (`loader_link_errno=0`) and, its plist setting
`DISABLE_TWEAKS`, logged `inserted-tweaks-disabled`. `serviceInfo` answered as
before; PineBoard kept its boot pid; the only reports were `bug_type` 313
SiriSearchFeedback entries, which the guest also wrote before the hooks.
There is no `bootstrap-root` line in the hook's log: its first spawns come
before the data volume where the log lives is mounted.

Turning both off (`fw set-patches tv4k`, `cfw update-environment`) logged
`removed the TV environment hooks` and `restored sbin/launchd from backup`;
the guest booted in 20 seconds with neither library nor `/vh`, the bootstrap
still installed. Turning them on again restored the hooked boot. Snapshots
`before-tvroothide` (no bootstrap) and `bootstrap-no-hooks` are on the VM.

## TV button, Home and Control Center

A USB keyboard cannot press the TV button: no keyboard-page key maps to it.
UIKit's `_UIEventHIDPressTypeForKeyboardHIDEvent` (UIKitCore, 23L5208m) maps
consumer page `0x0C`:

| Usage | Press type | Button |
| --- | --- | --- |
| `0x40` Menu | 17 | TV / Home |
| `0x1C0` | 500 | TV / Home (second type) |
| `0x223` AC Home | 101 | game controller Home |
| `0x30` Power | 104 | Power |
| `0x41`–`0x46` | 4, 0–3, 5 | Select, arrows, Menu |
| `0xE9` / `0xEA` | 102 / 103 | Volume |

PineBoard's `+[PBSystemGestureRecipe recipeForType:]` presents Control Center
(system gesture `0x1d`) on a long press of press types 17 or 500, on a press of
104 when the `allowPowerButtonToOpenControlCenter` default is set, or on the
game controller's Home. A long press of Menu (5) runs
`_cleanUpUIStackAndLaunchKioskAppWithReason:@"Long MENU press"`, so holding
Escape also returns to the Home screen.

vphoned's `input.hid` injects consumer events inside the guest. The existing
Home Screen action already sends `0x0C/0x40`. For an Apple TV guest the titlebar
Home button sends the press when the mouse goes down and the release when it
comes up, and the Mac's Home key (fn-← on a laptop) does the same with its
key down and up, so either one held opens Control Center. Device > Control Center, shown
only for an Apple TV guest, holds the same usage for 1.2 s. On 23L5208m a
`0x0C/0x40` press over `input.hid` returned from Settings to the Home screen,
and a 1.5 s hold opened Control Center.

## Apple TV 4K from its OTA

Apple publishes no IPSW for any Apple TV 4K. The full tvOS 26.6 (23L773) OTA
for AppleTV14,1 (J255, A15) is a 4.76 GB AEA archive whose key AppleDB records.
Its userland is arm64e and, like the HD's, monolithic: no cryptexes. It ships
the IOGPU Metal stack, and every import of the paravirtual GPU driver resolves
in its shared cache. The OTA has no root filesystem image, only 37
`payloadv2/payload.NNN` chunks, each a `pbzx`-compressed Apple Archive with
owners, modes, BSD flags and APFS compression per entry, plus the root
filesystem's `.mtree` (an IM4P `msys` around a `pbze`/LZFSE Apple Archive
manifest), `.root_hash` and `.trustcache`, and the J255 device tree.

An Apple TV 4K guest is the Apple TV HD's 26.6 IPSW (same build) restored with
the J255 identity, its userland swapped for the OTA's in `cfw install`.

### Creating one

```zsh
vphone-launchpad-cli vm create tv4k --device AppleTV14,1 --cpu 4 --memory 4096 --disk-size 48
```

or `vphone-cli vm create tv4k --device AppleTV14,1`, or in Launchpad New
Machine > Device > Apple TV 4K (3rd generation). The firmware catalog pairs the
4K with the HD's 26.6 IPSW and cloudOS 26.4, and lists the OTA's URL, length
and key; `fw prepare` downloads the OTA into `<ipsw cache>/ota/` under
`AppleTV14,1_26.6_23L773_OTA.aea`, or uses the copy already there. The machine
gets the `tvos-4k` preset. Step by step, with local files:

```zsh
"$cli" vm new tv4k --cpu 4 --memory 4096 --disk-size 48
"$cli" fw set-patches tv4k --preset tvos-4k
"$cli" fw prepare tv4k --device AppleTV14,1 \
  --iphone-source "$hd_266_ipsw" --cloudos-source "$cloud_ipsw" \
  --ota-source ~/.vphone/ipsws/ota/AppleTV14,1_26.6_23L773_OTA.aea
"$cli" fw patch tv4k
```

then DFU, `restore`, `cfw install` and launch as for the HD. `--ota-key
<base64>` gives the key for an OTA the catalog does not list; a local OTA of a
listed build takes the catalog's key.

### What `fw prepare` does

`fw prepare --device AppleTV14,1` resolves the IPSW as the HD's
(`VPhoneGuestDevice.restoreBase`), so the restore tree is
`iPhoneOS_AppleTV5,3_26.6_23L773_Restore` and the hybrid manifest is built
from the HD's identity, as for an HD guest. Then, with
`VPhoneOTAArchive` (`VPhoneKit/VPhoneArchiveKit/Transfer`):

1. Before any IPSW is unpacked, the OTA is decrypted far enough to read
   `AssetData/boot/BuildManifest.plist`: it must list AppleTV14,1 and be the
   IPSW's build. A wrong key fails here too.
2. After the restore tree is built, one pass over the OTA writes
   `AssetData/boot/Firmware/all_flash/DeviceTree.j255ap.im4p` into the
   tree's `Firmware/all_flash`, beside J42d's, and every
   `AssetData/payloadv2/payload.NNN` plus `payload_chunks.txt` into
   `<vm>/OTAUserland`. The `.ecc` files, firmware, kernel and BOMs are skipped.
   The chunks must be numbered from 0 and match the list one for one. The
   folder is assembled under a temporary name and renamed into place; a
   prepare for any other firmware removes a stale one.
3. `config.plist` records AppleTV14,1 and its 3840x2160 @2x screen. The
   paravirtual GPU driver and compiler plugin are staged into `.pcc-gpu` as for
   an iPhone: only a plain-arm64 guest skips them.

The reader uses the system AppleArchive framework (`libAppleArchive`), no
`ipsw`, `aea` or `aa` process. `ArchiveEncryptionContext` reads the AEA
header and takes the symmetric key; `ArchiveByteStream.decryptionStream`
returns nil for a wrong key. The decrypted archive is segmented: its top-level
entries are metadata (`TYP=M`), and each `YOP=E` (extract) entry's `DAT` blob
is another, uncompressed Apple Archive with the next run of files; `YOP=M` is
the segment manifest and `YOP=O` the owner and mode fix-ups. Each segment is
decoded from its parent's blob through a custom byte stream, and members stream
to disk in 8 MiB blocks, so the 4.76 GB OTA is read once and never held in
memory: the pass over the real OTA takes about a second. A decrypted archive
(`AA01`, or `pbz*` compressed) reads the same way without a key.
AppleArchive's Swift wrappers close their stream when released and a decoder
does not retain its input, so every layer is kept alive until the read ends;
without that the first header read fails with `ioError`.

`fw patch` keeps the recorded AppleTV14,1 although the HD manifest does not
list it, and `cfw install` takes the guest's own board tree when J42d's is
there too.

### What `cfw install` does

`system-tv-exp-ota_userland` empties the System volume and runs `/usr/bin/aa
extract` for each chunk as root, before every other guest step, then records
the chunk list on the volume so an environment update does not extract it
again. The GPU driver and compiler plugin get `LC_BUILD_VERSION` platform tvOS
(`MachOBuildPlatform`), an Apple ad-hoc re-sign and a resealed bundle; AMFI's
trust-cache check is already patched to accept any cdhash, so the HD's static
trust cache does not matter.

The `tvos-4k` preset is `tvos` with the GPU bundle and
`system-tv-exp-ota_userland` on and both TV TPRO patches off: arm64e dyld
handles hardware TPRO, and those patches are for plain-arm64 dyld only. The
installer admits the GPU bundle and the userland swap only for an arm64e TV
guest (`FirmwareGuestPatchResolution.tvArm64eGuestPatches`).

### Results

Prototype, 2026-10-15 (VM `tvtest-4k`, staged by hand with `ipsw`): the guest
boots to the tvOS home screen. vphoned answers with `model` AppleTV14,1, tvOS
26.6, a 1920x1080-point screen at 2x; screenshots are 3840x2160. Control
Center's platters and the dock shelf render as materials. On the host the VM
has five `ParavirtualizedGraphicsGPUTask` processes (each HD guest has two),
and one had used 4.5 s of GPU time while every HD guest task read 0: the guest
renders through the paravirtual GPU. Settings > About reports tvOS 26.6
(23L773) and 2160p UHD at 120 Hz. Holding the TV button over `input.hid`
opened Control Center with frosted tiles, and the VM's GPU task (attributed to
its launcher by `responsibility_get_pid_responsible_for_pid`) gained GPU time
meanwhile.

Native path, 2026-10-15 (VM `tv4k-native`, `vphone-launchpad-cli vm create
--device AppleTV14,1 --preset tvos-4k --no-template` with the local HD and
cloudOS IPSWs): `fw prepare` found the OTA already in `~/.vphone/ipsws/ota/`
under its catalog name, checked its manifest, and staged J255's tree and the 37
chunks; the staged chunks are byte-identical to `ipsw`'s. Restore and `cfw
install` (93 patches, userland extracted, GPU driver retargeted) completed and
vphoned answered on the first boot. The guest starts at TVSetup's Language
screen at 3840x2160 with the Siri Remote artwork of the 4K, `device.info`
reports tvOS 26.6, and the VM has four `ParavirtualizedGraphicsGPUTask`
processes, one of whose GPU time went from 0.27 s to 0.95 s over twelve focus
moves sent with `input.hid`. The installed Launchpad (2.9.2) predates the
Apple TV support in New Machine and ran the iOS template trim and setup boot
after the install; setup failed at the service profile, which has no TV port.
That does not touch the steps above, and the guest booted normally afterwards.

Open issue, display freeze on the 4K: after some time of use, mostly after the
app switcher, `tvtest-4k` stopped updating its screen. Input still reached
PineBoard, `input.hid` and vphoned kept answering, the GPU task kept gaining
GPU time and the host kept scanning out the last frame. A guest spindump
(`/usr/sbin/spindump -notarget 8 10` started as a launchd job through vphoned's
`services.load`, symbols from `ipsw dyld a2s`) showed
`com.apple.coreanimation.display.primary`
(`CA::WindowServer::IOMFBServer::thread_body`) starved while the rest of
backboardd ran. The HD never froze. A 20-minute soak (launch Settings, move
focus, open the app switcher, then check that holding the TV button changes
the screen) found no freeze at 60 Hz (87 cycles, `kernel-cfw-display_promotion`
blocked) or at 120 Hz (40 cycles), so the refresh rate is not shown to be the
cause and the trigger is still unknown.


Apps, video, long-term stability and Apple services are untested.

## tvOS 27 on the Apple TV 4K

tvOS 27 dropped the Apple TV HD (AppleTV5,3) and the first 4K (AppleTV6,2);
AppleDB lists 27.0 (24J361) and the 27.2 betas for AppleTV11,1 and AppleTV14,1
only, as OTAs and recovery images, with no IPSW for any device. The 27.0 full
OTA for AppleTV14,1 is a 4.83 GB AEA archive whose key AppleDB records. Its
layout is the 26.6 one: monolithic, no cryptex, `payloadv2` chunks, the root
filesystem's `.mtree`, `.root_hash` and `.trustcache`, and the J255 device tree.
(Checked on the AppleTV11,1 27.0 OTA, a plain zip, from its central directory.)

The 27.0 OTA needs a Mac on macOS 27. Its `payloadv2` chunks are `pbzm`, not
`pbzx`: LZRAVEN (`COMPRESSION_LZRAVEN`, 0xD05), which libcompression gained in
macOS 27, and a chunk's first block decodes to `YAA1` only there. On macOS
26.6.2 neither AppleArchive nor `aa` reads it, and the creation failed after
the restore, when `cfw install` unpacked the userland (2026-10-23). The catalog
records the requirement (`VPhoneOTARelease.minimumHostMacOS`): on an older Mac
`fw catalog` and the default pairing stop at tvOS 26.6, an explicit 27.0 source
is refused before anything is downloaded, and staging refuses a `pbzm` chunk by
name.

So a 27 guest is the 26.6 one with a later OTA: the HD's last IPSW, 26.6, is
the restore base and only the userland changes. `VPhoneOTARelease.baseVersion`
records the base an OTA goes over. The 4K's tvOS 27.0 pairing names the OTA
itself, and `fw prepare` maps a catalog OTA given as `--iphone-source` to its
base IPSW and stages that OTA:

```zsh
vphone-launchpad-cli vm create tv27 --device AppleTV14,1 --preset tvos-4k --no-template \
  --iphone-source https://updates.cdn-apple.com/2026FallFCS/fbf3c544-b770-4756-9cca-abfb2d3cb65e/com_apple_MobileAsset_SoftwareUpdate/9bf3ad6ac49c25016599bbb77d8ea1c612cb745eb7ee9e502af1926c860b7e18.aea \
  --cloudos-source https://updates.cdn-apple.com/private-cloud-compute/c0ecdb4b310cf5239ab2b248dd3098eec297dc5aa3bbe6ada27273262b0b8b64
```

`fw prepare` also writes `OTA-SystemVersion.plist` (the OTA's version and
build) into the restore tree, and the pipeline takes the base version from it
before `iPhone-BuildManifest.plist`: the guest patches meet the 27 userland, not
the 26.6 one, so the plan has to resolve for 27. The `tvos-4k` preset turns on
the iOS 27 shared-cache patches (`FirmwarePatchSetCatalog.tvOS27UserlandPatches`:
`dyld-boot-iomfb_force_kern`, `dyld-boot-lockdown_mode`,
`dyld-boot-lsd_embedded_reg`, `dyld-boot-maxslide`, `dyld-boot-xpc_lwcr`), which
an arm64e TV guest admits; each is gated on 27, so a 26.6 4K never meets them.
The iOS 27 kernel patches (`kernel-boot-iomfb_swapend` and the others gated on
27) come with the plan's version. `system-tv-exp-ota_userland` was gated on 26
and a 27 plan dropped it: the HD's plain-arm64 26.6 userland then booted on the
J255 identity and panicked at first boot. It now applies from 26.0 on, and `cfw
install` refuses a full install of a device without an IPSW whose plan lacks it.

Result, 2026-10-16 (VM `tv27-4k`, cloudOS 26.4, 104 patches): first boot
reached TVSetup's Language screen and vphoned answered. `device.info` reports
AppleTV14,1 at version 27.0.0 with a 1920x1080-point screen at 2x;
screenshots are 3840x2160. The host window shows the guest screen, so tvOS 27,
like iOS 27, presents through `_virt_Swap*` and needs the force-kern patch on
the 26.4 kernel. Six focus moves over `input.hid` moved the selection to
Deutsch (the title became "Sprache"), and the VM's paravirtual GPU task gained
0.31 s of GPU time meanwhile. locationd, backboardd and PineBoard kept their
pids over a minute. The vphoned `services.print` RPC kills vphoned on this
guest every time (launchd restarts it within seconds), as icli's launchd session
lookup does on tvOS; other RPCs work. The locationd startup deadlock iOS 27
userlands hit on the 26.4 kernel (`Research/Guest/locationd_startup_deadlock.md`)
has not been measured over repeated boots here.
