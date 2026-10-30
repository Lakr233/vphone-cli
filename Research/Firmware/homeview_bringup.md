# HomeView virtualization bringup

## Evidence and scope

Inspected 2026-10-30, using the supplied Pallas SoftwareUpdate response, extracted
AssetData at `__tvOS/HomeViewBundle`, and root filesystem at
`__tvOS/__HomeView_27.2` under the operator's `_AppleOSImages` directory. These
are firmware observations, not results from running a HomeView VM. **No HomeView
VM has been booted or restored in this investigation.**

The Pallas response advertises a full, encrypted AEA update for 27.2, build
`24V514`, supporting `HomeAccessory17,1` and `HomeAccessory17,2`. Its
`SupportedDeviceModels` array names only `J490AP`; the extracted boot manifest
covers both products and includes both `DeviceTree.j490ap.im4p` and
`DeviceTree.j491ap.im4p`. Keep both board identities rather than aliasing J491 to
J490. This asset is not a restore IPSW. The initial implementation uses the
existing Apple TV HD restore-base/OTA-userland workflow; its suitability for
HomeView remains a bringup hypothesis pending restore and boot validation.

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
