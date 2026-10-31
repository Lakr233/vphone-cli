# HomeView virtualization bringup

## Current tested result

`HomeView` is installed in the normal Launchpad library and left running on
HomeAccessory17,1 / J490, HomeView 27.2 (24V514), cloudOS 26.4 (23E5207q), with
8 CPUs, 8 GiB RAM and a 64 GB disk. Its current host and guest bundle is
`2.15.0-local.176e4e80`; the VM-specific setup bypass is enabled. Shipped
`homeview` still defaults to native setup. The `native-setup` stopped snapshot
preserves the working Hello/proximity-setup state before enabling the bypass;
`native-baseline` preserves the earlier clean boot before the compatibility
repairs, for reproducing the original display-service failure.

Verified after the two scoped sandbox exception repairs: native Hello and
Hold iPhone Nearby setup, actual UserProfiles guest-profile retrieval,
bypass enable and exact preference restoration on disable, stable BreadBoard,
framebuffer at 1088 square / 544 square points / 2x, virtual USB touchscreen,
and native touch navigation dashboard → World Clock → Add City → Close →
dashboard. No clock, account, HomeKit or provisioning choices were saved.
`device.info` now completes. Final boot has setup pending false, setup_done
false, no Setup.app process, and stable BreadBoard PID 39. The host window's
OS subtitle uses the tvOS platform independently of remote-versus-touch input.

Guest DNS resolution of `captive.apple.com` and a bounded HTTPS fetch of its
connectivity success page both work. The dashboard still shows Weather
Unavailable and a connectivity warning; those higher-level services have not
been provisioned or validated. HomeView-shell accessibility discovery still
uses IcliKit's PineBoard fallback and cannot verify the shell foreground;
accessibility in native World Clock works. Panel density/dimensions remain
provisional, and audio, camera and physical-device proximity pairing are not
validated here.

Screenshots (local build artifacts, not firmware inputs):

- `.build/homeview-validation/native-setup.png`
- `.build/homeview-validation/dashboard.png`
- `.build/homeview-validation/touch-city-dialog.png`
- `.build/homeview-validation/current.png`

Final code validation: VPhone bundle build/admission and installed-bundle
preflight pass; 57 patch catalog/resolution tests and 400 daemon logic checks
pass for the runtime repairs. Earlier model/device-tree suites remain recorded
below. No Python files were added.

## Evidence and scope

Inspected 2026-10-30, using the supplied Pallas SoftwareUpdate response, extracted
AssetData at `__tvOS/HomeViewBundle`, and root filesystem at
`__tvOS/__HomeView_27.2` under the operator's `_AppleOSImages` directory. These
began as firmware observations. The subsequent clean VM restore and first
runtime failure are recorded below; usable native UI and touch remain unverified.

The Pallas response advertises a full, encrypted AEA update for 27.2, build
`24V514`, supporting `HomeAccessory17,1` and `HomeAccessory17,2`. Its
`SupportedDeviceModels` array names only `J490AP`; the extracted boot manifest
covers both products and includes both `DeviceTree.j490ap.im4p` and
`DeviceTree.j491ap.im4p`. Keep both board identities rather than aliasing J491 to
J490. This asset is not a restore IPSW. The initial implementation uses the
existing Apple TV HD restore-base/OTA-userland workflow. A later clean restore
reached vphoned and backboardd, but the native shell crashes before usable UI.

## Device presentation

Decoded both unencrypted `dtre` IM4P LZFSE payloads with system Compression and
parsed the flattened device-tree property and child records. The observations
are:

| Property | J490 | J491 |
| --- | --- | --- |
| root model | `HomeAccessory17,1` | `HomeAccessory17,2` |
| target type | `J490` | `J491` |
| target subtype / unique model | `J490AP` | `J491AP` |
| artwork idiom | `home` | `home` |
| artwork scale | uint32 `2` | uint32 `2` |
| artwork subtype | uint32 `1088` | uint32 `1088` |
| app Mach-O architecture | `arm64` | `arm64` |
| artwork display gamut | `sRGB` | `sRGB` |
| framebuffer identifier | string `0` | string `0` |

J490 also has product description `HomeView`, a physical SPI `multi-touch` node
with compatible `hid-transport,thirdpartyspi`, and no `horseman`, `siri-hub`, or
`supports-driverkit` property. Do not copy the donor's SPI hardware into the
virtual machine. Its virtual USB touchscreen requires the research platform's
input path and DriverKit availability.

**Display width, height, and PPI remain unverified.** A 1088 × 1088 virtual canvas
and its chosen density are provisional bringup configuration, not a recovered
panel specification. The artwork subtype alone does not establish a square
panel. Only the 2× scale is directly confirmed by the board trees. The firmware
also contains `System/Library/Display/J490/159-od.bin`; its presence does not
establish geometry without a format-aware interpretation.

## Native shell and setup

`System/Library/LaunchDaemons/com.apple.BreadBoard.plist` declares an
`EmbeddedHomeScreen`, runs as `mobile`, and keeps
`/System/Library/CoreServices/BreadBoard.app/BreadBoard` alive. Its Info.plist
names bundle `com.apple.BreadBoard`, AppleTVOS 27.2, and `UIDeviceFamily` values
3 and 8. The executable delegates to BreadBoardFoundation and
BreadBoardFramework. This is a separate home-screen shell from Apple TV's
PineBoard and HomePod's SoundBoard.

Extracted the following libraries from the supplied dyld cache into scratch
storage with `ipsw dyld extract --slide --objc`, then opened them with REA/Hopper:

| Image | Extracted SHA-256 |
| --- | --- |
| BreadBoardFramework | `f3336f3e9aade1bdfb02fcb50a10880f42c26f892119f635a29aa9e97573bd93` |
| PlasterBoard | `eab287030957f20a1fc01ff955244fef995f70599fe5d7cad84a3b6e9a814096` |
| SetupAssistant | `98839ae56bab964195fa9e333c238640a9f5deb3525104f15fed5fd4e641c81f` |

BreadBoardFramework contains a Buddy presenter and a log for Buddy reporting
setup configuration complete (REA
`ev_bc929f1c0f4b7e7e922f924824529734a8e91f15ed7a567b4ead85a159308940`).
PlasterBoard imports `BYSetupAssistantNeedsToRun` and contains
`PLSetupAssistant.Monitor` (REA
`ev_6f2d43c1eac88b80251d26254d9a76334d29c8de8e64df24ba86b398736b8ea2`).
Those strings identify the path but do not by themselves prove its behavior.

SetupAssistant provides the useful implementation evidence:

- `_Internal_BYSetupAssistantNeedsToRun` at analysis address `0x1a72d0aa8`
  first reads `ForceNoBuddy` through `BYPreferencesController.buddyPreferences`.
  A true value returns false. Otherwise the HomeAccessory branch reads
  `SetupDone` and returns its inverse. It does not take Apple TV's additional
  upgrade mini-buddy path. REA
  `ev_80062f779da35c9d883b73d5df5b64dbdd7e836a89c033a9cf6f15d8edc59037`.
- Public `BYSetupAssistantNeedsToRun` at `0x1a72c9890` independently checks the
  same `ForceNoBuddy` override before the cached launch sentinel. REA
  `ev_bb935bac166764c4f67ee86246c4d3765b74fe7a049cc284d3837ed552fbe6e2`.
- `BYSetupAssistantHasCompletedInitialRun` at `0x1a72d0d58` returns true for
  `ForceNoBuddy`, otherwise reads `SetupFinishedAllSteps`. REA
  `ev_d400f50b3f8f9ec501e79a941a41c9930cedcf914f3bdda860ea77bfb12dc782`.
- The `buddyPreferences` singleton initializer at `0x1a72d75d4` passes the
  `com.apple.purplebuddy` domain to its initializer. REA
  `ev_cb855ce0e90c1720e643fc55cd2afe19dfab9998e3fe695ae32078208c32cc4c`.
  The shared-cache Objective-C selector stubs at `0x1a806dcc0` and
  `0x1a8004800` were decoded and their selector data read to confirm
  `buddyPreferences` and `boolForKey:` respectively. Preference reads use
  `CFPreferencesCopyValue` with the controller's domain, current user, any host.
- `BYSetupAssistantPrepareLaunchSentinel` at `0x1a72d109c` evaluates native
  setup state and publishes transitions through the donor framework. REA
  `ev_42c8fe42dfebb1f8ee69566e8131a8137daf6e3ccf08ea7b68f083152e69f570`.

Addresses above identify this analyzed build only. They are not patch offsets
and must never be used by runtime patch logic. Hopper's function dossiers do not
provide complete function body ranges; recovered pseudocode and indirect calls
retain that limitation. All REA native sessions were closed after inspection.

## Optional setup bypass

The existing native setup maintenance executable has a `--homeview` mode. It
runs as mobile (uid/euid 501), verifies HomeAccessory17 or J490/J491 hardware
identity, and reads `/usr/share/vphone/HomeViewSetup.plist`. When enabled it sets
only `ForceNoBuddy` in mobile's `com.apple.purplebuddy` preferences. It does not
set `SetupDone`, change HomeKit or account state, or terminate HPSetup processes.

Before mutation it atomically saves the exact prior value, including absence,
in `HomeViewSetupOriginal.plist` under mobile's
`Library/Application Support/vphone`. Repeated enabled runs preserve the
original journal. Removing the enabled policy restores that value, verifies the
native setup state and launch sentinel, and only then removes the journal.
`HomeViewSetupStatus.plist` records the native API results and errors. The
maintenance launch entry must remain installed for a later deselection to
restore the saved preference.

The underlying state helper now accepts an explicit key list. The HomePod
wrapper continues to use its original two completion keys. HomeView uses only
`ForceNoBuddy`; journals from one key set cannot be applied as the other.

## Validation and remaining bringup work

Host native state tests cover an originally absent, false, and true
`ForceNoBuddy`, repeated enabling, exact restoration, unrelated setup choices,
and rejection of a journal from the other mode. Existing HomePod journal and
process-ordering tests pass. The guest sources pass a tvOS arm64e syntax check
with `-Wall -Wextra -Werror`. These checks do not establish that BreadBoard
starts, touch reaches it, or the notification dismisses an already-presented
setup scene on a VM.

On a fresh machine, first validate OTA staging, model detection, restore-base
handoff, the shared-cache/kernel compatibility, paravirtual graphics, and the
native BreadBoard setup screen with the bypass off. Then validate touch on the
virtual USB input path. Enable the bypass and inspect both its status plist and
the shell's visible response; expected native results are `NeedsSetup=false`
and `CompletedInitialRun=true`. Disable it and repeat after reboot, checking
that the journal restores the original override and setup choices remain
unchanged. Capture serial logs and the first failing process before adding
further compatibility patches. Audio, camera, proximity, HomeKit provisioning,
account services, and final panel geometry remain unvalidated.

## CLI workflow

The `homeview` preset is selected automatically for either supported product.
The native setup screen remains enabled by default. Creating a machine requires
macOS 27 or later to unpack this full OTA's LZRAVEN payload:

```zsh
vphone-cli vm create HomeView --device HomeAccessory17,1
```

Use `HomeAccessory17,2` for the J491 board. To opt into the setup bypass during
creation, export a preset through the existing patch-selection interface:

```zsh
vphone-cli fw export-preset --preset homeview \
  --allow system-homeview-exp-setup_bypass --output /tmp/homeview-no-setup.plist
vphone-cli vm create HomeView --device HomeAccessory17,1 \
  --preset /tmp/homeview-no-setup.plist
```

On an existing stopped machine, change the guest patch choice, install it, and
boot again:

```zsh
vphone-cli fw set-patches HomeView --preset homeview \
  --allow system-homeview-exp-setup_bypass
sudo vphone-cli cfw update-environment HomeView
vphone-cli vm launch HomeView
```

Return to native setup by setting the `homeview` preset without the allow
list, updating the environment, and rebooting. The helper stays installed even
when off so it can restore its original preference journal at the next boot.
The helper does not claim that accounts, activation, networking, or HomeKit
provisioning completed. The installer admits only the HomeView guest patch
subset; Apple TV setup/focus/activation adapters and HomePod-specific patches
remain excluded.

This catalog adds the `homeView` family and `homeview` preset to the
Launchpad/CLI contract. Both components move to series 2.15, and Launchpad's
minimum bundle and device-to-preset mapping are updated together.

Validation on 2026-10-30: all 701 VPhoneCoreKit tests, 109 selected firmware
catalog/resolution/device-tree tests, and 32 patch-model tests pass in Xcode.
The native setup journal/process tests and Launchpad bundle-name/binding tests
also pass, including HomeView standalone restore classification. Both the
finished VPhone 2.15.0 scheme and Launchpad build successfully in Xcode. The
bundle passes admission and a separate deep/strict signature verification.
CLI smoke checks confirm both catalog identities, their separate OTA cache
names, the default-disabled setup patch, and export of an opt-in preset.
A network-backed `fw prepare --list` check could not resolve its server in this
execution environment. No firmware download, restore, or VM runtime result is
claimed by these checks.

## First clean runtime, 2026-10-30

The first attempt through an installed 2.14 Launchpad accidentally applied its
older non-HomeView slimming behavior. It is not a valid native baseline. A fresh
restore through the lower-level HomeView-aware path replaced that state before
the observations below. The clean Data volume reports `setup_done=false`,
setup pending, and service profile `none` (`record=null`, `disabled=[]`). No
setup preference or UI input was changed during this baseline inspection.

The clean VM reaches guest vphoned and `backboardd`. The actual macOS VM window,
captured through CUA, remains black with the white Apple boot logo. The window
reports HomeView, iOS 27.2.0 and a guest NAT address. This is boot graphics, not
evidence that BreadBoard renders a native HomeView scene. `device.info` and the
guest-dependent host screenshot request hang, while independent process, file,
service and crash-list RPCs continue to answer. The stalled diagnostic clients
were stopped. No successful guest screenshot or accessibility hierarchy was
obtained, so there was no eligible setup control to touch.

`services.print` shows `com.apple.backboardd` running as mobile, PID 75, one
launch and no exit. Its advertised endpoints include
`com.apple.backboard.display.services`, `com.apple.CARenderServer`, and the HID
services. `com.apple.BreadBoard` is installed and launched correctly, but its
service record shows eight runs and eight successive SIGTRAP crashes, with a
roughly ten-second relaunch cadence. This is a shell initialization failure,
not failure to import the launch daemon.

The pulled `BreadBoard-2026-10-30-191634.ips` (PID 319) reports
`EXC_BREAKPOINT` / `SIGTRAP` on the main thread:

```text
BKSDisplayServicesStart + 436
-[BKSSystemShellService initWithConfigurator:] + 716
-[FBSystemShell _initWithOptions:] + 664
FBSystemShellInitialize
BreadBoardFramework
```

The inspected donor BackBoardServices extraction has SHA-256
`f78622e9194149789fa2804cf69ee6c232160f07350e48920183687a27c1f7c3`.
REA inspection of `BKSDisplayServicesStart` at analysis address `0x19d2dca20`
shows that the fault at `+436` is the assertion for a **nonzero main-screen
query result**, rather than either of the later zero-width/zero-height
assertions. Evidence:
`ev_af213f97676042412efe1eed3a949f9eaf0b4ac9d63fffd56284337923b52723`.
Its `__BKSDisplayServicesGetMainScreenInfo` helper at `0x19d2dccf4` calls
`__BKSServerPortHelper` for `com.apple.backboard.display.services`, then makes
the main-screen MIG query. Evidence:
`ev_be76b6a28e2a7ad9a11695498345d971ab123e931d6932beda4a1d8e30f8b2b9`.
These addresses are evidence for this build only, not patch anchors.

Donor BreadBoard entitlements, decoded with `codesign` and `ldid -e`, explicitly
select `com.apple.private.sandbox.profile:embedded = temporary-sandbox`. Their
existing global mach-lookup exception list includes the system-app-server,
backlightd and AttentionAwareness services but omits
`com.apple.backboard.display.services`, `com.apple.CARenderServer`,
`com.apple.iohideventsystem`, and the backboard HID services. This resembles the
already documented Campo failure on a 27-series userland with the 26.4 research
kernel. The combination of the native communication assertion, the live
backboard endpoint, and the missing donor exceptions supports the same repair.
**A direct BreadBoard sandbox denial was not captured:** a bounded twelve-second
kernel live-log sample contained unrelated Protobox/Autobox denials, and the
BreadBoard live-log sample was empty. Historical `log show` could not run
because this guest does not contain `/usr/bin/log`.

The new `system-breadboard-exp-mach_lookup` declaration merges the existing
Campo backboard/frontboard service set into BreadBoard's own entitlements,
preserving its other entitlements and a backup for reversal. It is enabled by
the `homeview` preset only. **This is a targeted hypothesis pending the updated
bundle's runtime retest.** Do not count it as a successful native UI or touch
fix until BreadBoard stays alive and the setup screen renders.

The baseline also produces repeated `duetexpertd` crashes at
`ATXEnableMobileAssetDataVault + 580`, with the recorded assertion
`Failed to initialize datavault for DuetExpertCenterAsset`, and ProxiedCrashCopier
crashes. They are separate observations; fixing the BreadBoard communication
path does not establish that these services recover. No setup-bypass runtime
test was performed while the shell could not initialize. All REA sessions were
closed after the static follow-up.

## BreadBoard entitlement repair retest

Retested installed bundle `2.15.0-local.ceb99033` after its guest environment
update. The installer merged fifteen previously absent services into
BreadBoard's existing exception list (73 total). Native guest screenshot
capture now succeeds; `/tmp/homeview-native-before.png` and
`/tmp/homeview-native-after.png` show the 1088-square virtual display with the
Apple boot logo. No native setup control is visible. `ui.tree` fails with
`frontmost application could not be verified`, so no touch was attempted.

The original display-service assertion is gone. BreadBoard reaches its
UIApplication main loop, then crashes on a cooperative Swift task. The new
`BreadBoard-2026-10-30-192039.ips` (PID 249) has
`_assertionFailure(_:_:file:line:flags:)` followed by BreadBoardFramework offset
`0x1b4b2c`. REA maps that continuation to a fatal error in
`BreadBoardFramework/PersonaIdentifier+Personas.swift`, line 118:
`failed to retrieve guest persona identifier: `.
Evidence: `ev_ecd077dff6ab3a600304541c83d3258a4d5d86d0065bf439eacf714858545c5f`.
The caller creates `UPProfileStore` and asynchronously retries the
`UserProfiles` Swift `guestProfile()` API. This is a separate dependency from
the initial display-service failure; it is not an assertion to bypass.

`userprofilesd` is running as mobile (PID 131), with one launch and no recorded
crash. A read-only scripting probe confirms that UserProfiles selects
`UPProfileStoreCoordinator`, rather than its unsupported-platform null source.
Static `_makeProfileStoreSource` corroborates that distinction (REA
`ev_6a6ce20de08f0343d0c04a6418221da2455de8cae9010edc6b25433e00d35221`).
There are no dedicated multiuser/persona/guest capabilities in either donor's
product-property inventory. The daemon's unsupported-guest-profile branch
would return code 2 with `This platform does not support the guest profile`
(REA `ev_68b03ef664942205bb648dc6d4defb364b0836cd491f65d0923166b1e0abecd3`).

A bounded native Foundation diagnostic, run as mobile with the observed
UserProfiles read-write entitlement, successfully retrieves an empty profile
snapshot with no error. Its read-only `fetchGuestProfileWithCompletion:` call
returns `UPProfileStoreErrorDomain` code 1 (`InternalError`), with underlying
`NSCocoaErrorDomain` code 4099:

```text
The connection to service named com.apple.mobile.keybagd.UserManager.xpc
was invalidated: Connection init failed at lookup with error 159 - Sandbox restriction.
```

This establishes a failed native dependency lookup rather than absence of
ordinary profile records. A second mobile diagnostic added BreadBoard's observed
UserManager client permissions: both service exceptions and persona
fetch/setbundle entitlements. It returned the identical underlying sandbox
restriction, while snapshot retrieval still succeeded. Merely adding those
client permissions does not repair the request; combined with the daemon's
native call path, this points to the daemon-side dependency. This rerun took
place after the root investigation enabled the optional setup policy, so the
persona failure also survives that policy. BreadBoard's donor already has
both UserManager service exceptions and persona fetch/setbundle entitlements.
The userprofilesd donor selects `temporary-sandbox` and has persona
create/delete/fetch entitlements, but its global exceptions include
`com.apple.mobile.usermanagerd.xpc` and omit
`com.apple.mobile.keybagd.UserManager.xpc`. Its native
`UPDPersonasController.createGuestUserPersonaWithCompletionHandler:` calls
`UMUserManager.sharedManager` then
`createUserPersona:passcodeData:completionHandler:` (REA
`ev_ebe027049ce1a2b12e292d54d05e5437dff379ab8d281b0687a425298893e4eb`).
The missing backend exception is therefore a focused candidate, pending
caller isolation and runtime repair validation. No profile reset, synthetic
persona, account enrollment, or setup completion was performed by the
diagnostic.

## Native setup renders after the backend lookup repair

Bundle `2.15.0-local.dc3b7ead` adds only
`com.apple.mobile.keybagd.UserManager.xpc` to userprofilesd's own lookup
exceptions. With the optional setup bypass disabled and its saved override
restored, the native maintenance status reads `Enabled=false`,
`Succeeded=true`, `NeedsSetup=true`, `CompletedInitialRun=false`.

On this boot BreadBoard stays alive as PID 38, with last exit status zero.
The actual native `Setup.app` appears as PID 234. The first screen renders the
orange animated Hello scene and `Hold iPhone Nearby`; screenshots are
`/tmp/homeview-native-working-before.png` and
`/tmp/homeview-native-working-after.png`. Guest geometry is 544 × 544 points
at scale 2, matching the configured 1088 × 1088 virtual canvas. The host
reports `mouse_uses_pointer=false`. No clipping or overlapping text was seen
on this screen. This confirms the chosen virtual canvas works for initial UI;
it does not establish the physical device's panel geometry or density.

The accessibility tree exposes only a non-clickable `InstructionText` label,
so this native proximity-setup screen offers no actionable button to test
without provisioning. One harmless host touchscreen tap at the label center
(272, 463.75 points; 544, 927.5 screenshot pixels) is accepted. The recaptured
tree retains the same Setup PID, with the instruction now reading
`Make sure iPhone Bluetooth is on.` The instruction may rotate independently,
so this is not proof of a touch-triggered navigation transition. It confirms
host input submission; interactive native-control touch behavior still needs
a screen with an actionable control. Setup remains pending and `SetupDone`
remains false; no account or HomeKit provisioning was performed.

The same mobile native diagnostic with the matched UserManager client
entitlements now returns an actual `UPGuestProfile` with a native persona UUID
and **no NSError**. Snapshot retrieval also succeeds. This result, together
with the unchanged healthy BreadBoard PID and visible native setup UI,
validates the scoped userprofilesd backend lookup repair for this build. It
does not depend on the optional setup bypass. The diagnostic binary is staged
only in guest `/var/tmp` for investigation and is not a shipped component.

## Final native touch and setup-bypass validation

The same `.dc3b7ead` bundle was booted with the optional bypass on. Its native
maintenance verification reports `NeedsSetup=false` and
`CompletedInitialRun=true`; guest `setup.status` reports `pending=false`,
`running=false`, while `setup_done` remains **false**. Thus the bypass does not
write setup completion flags. The earlier off-mode boot restored its saved
override and rendered native Setup, validating the policy's inverse as well.

BreadBoard remains alive as PID 39, last exit zero. The native HomeView home
screen renders a green dashboard with the large date, month calendar, analog
clock and weather area. `/tmp/homeview-bypass-home.png` records this state.
The weather area initially displays loading placeholders, then explicitly
`Weather Unavailable`; World Clock advertises `No Internet Connection`.
No account or HomeKit provisioning was attempted to change that state.

Touch navigation is now verified against native actionable controls, using the
host's virtual touchscreen path:

1. A dashboard clock tap opens native World Clock (PID 358). The home shell's
   AX foreground detection is unavailable, so that initial tap used the
   screenshot as a bounded fallback. Once World Clock is foreground its
   accessibility tree reports its actual labels, buttons and hitpoints.
2. A host touch at its fresh Add hitpoint (477, 477 points, converted to
   954, 954 screenshot pixels at 2×) opens `Choose a City`.
   `/tmp/homeview-bypass-after-touch.png` records the native sheet.
3. A host touch at the sheet's fresh Close hitpoint (56, 56 points; 112, 112
   pixels) dismisses it. The recaptured tree again shows only the original
   Cupertino and New York clocks. No city or preference was added.
4. An upward gesture returns to the dashboard, verified in
   `/tmp/homeview-bypass-final.png`. The VM is left running in this state.

No overlapping or unexpectedly clipped controls were observed in the home
dashboard, World Clock or city chooser. Normal partial list content below the
viewport scrolls beyond the panel. The 1088-square virtual canvas is usable
for these verified native scenes; the physical display size/PPI remains
unestablished.

The one `device.info` retry also completes after the native shell boots,
reporting `model=HomeAccessory17,1`, native software `27.2.0`, kernel `25.4.0`
and a 544-square logical screen at 2×. Independent service checks after the
touch test still show BreadBoard PID 39 with no exit, and setup remains
suppressed without marking it done.

One automation limitation remains: on the HomeView dashboard,
`apps.foreground` incorrectly attempts the Apple TV `com.apple.PineBoard`
fallback and reports PID zero/unverified; `ui.tree` therefore cannot inspect
the shell. Foreground application AX works, as demonstrated by World Clock
and its city chooser. This does not prevent host touch input or native UI
operation, but shell-specific accessibility discovery needs a HomeView port.

The temporary diagnostic path `/var/tmp/homeview-profile-probe` was checked
after the final test and is absent. No diagnostic helper ships in the guest
environment. No REA or device-control session remains open, and no further
setup/account/provisioning action was performed.
