# Repository naming and shared module review

Scope: first-party Swift sources, SwiftPM targets, tests, scripts, and current
documentation. Vendored C, firmware format names, kernel symbols, wire keys,
command spellings, and historical evidence retain their established spelling.

## Names changed

| Former name | Current name | What it owns |
| --- | --- | --- |
| `VPhoneVMKit`, `VPhoneVM*` | `VPhoneVirtualMachineKit`, `VPhoneVirtualMachine*` | Running guest, VM commands, lifecycle, window, hardware and picker |
| `VPhoneFW*` | `VPhoneFirmware*` | Firmware CLI commands and source selection |
| `VPhoneCFW*`, `CFW*` | `VPhoneCustomFirmware*`, `CustomFirmware*` | Custom firmware installation and patches |
| `DSC*` | `DyldSharedCache*` | dyld shared cache readers and patchers |
| `KernelJB*`, `IBootJB*`, `KernelEXP*` | `KernelJailbreak*`, `IBootJailbreak*`, `KernelExperimental*` | Firmware patch variants |
| `VPhoneKit` | `VPhoneAPIKit` | Public HTTP and WebSocket client and typed JSON values |
| `VPhoneControl`, `VPhoneHostControl` | `VPhoneGuestControl`, `VPhoneHostAutomationServer` | Direct guest VSOCK client and host Unix socket automation, respectively |
| `VPhoneRestoreBridge` | `VPhoneRestoreService` | In-process probe, SHSH request, and restore API |
| `VPhoneBundleOps`, `VPhoneRestoreOps` | `VPhoneBundleOperations`, `VPhoneRestoreOperations` | Bundle and restore support in `VPhoneCore` |
| `VPhoneCreateOrchestrator` | `VPhoneVirtualMachineCreator` | Native `vm create` flow |
| `NewBundleSpec`, `PropertySpec`, `OpenAPISpec`, `FileOpError` | `NewBundleConfiguration`, `PropertyDefinition`, `OpenAPIDocument`, `CryptexFileOperationError` | Bundle input, device tree definition, API document, and cryptex errors |

The CLI's `VPhoneFirmwareSelection` also became
`VPhoneFirmwareSourceSelection`: the former conflicted with a core firmware
matrix result. `sendDevModeStatus()` became `isDeveloperModeEnabled()`;
`sendVersion()` became `guestBinaryHash()` because the endpoint returns a
SHA-256 hash. The matching menu label is now **Guest Agent Hash**.

Directory names follow their contents: `VPhoneVMKit` to
`VPhoneVirtualMachineKit` (including `VM` to `VirtualMachine`, `Interface` to
`UserInterface`, and `Devices` to `HostDevices`), `CFW` to `CustomFirmware`,
`DSC` to `DyldSharedCache`, `JBPatches` to `JailbreakPatches`, `EXPPatches` to
`ExperimentalPatches`, generic `Patches` to `BasePatches`, `Filesystem` to
`CryptexFilesystem`, custom firmware `Patches` to `ExecutablePatches`,
patcher `Core` to `PatchInfrastructure`, VM kit `Guest`
to `GuestCommunication`, and the guest `Swift` folder to `Daemon`. The research
folders `kernel_patch_jb` and `kernel_info` became
`kernel_jailbreak_patches` and `kernel_symbols`.

These source-level changes include **breaking Swift import and type names**
for external clients of `VPhoneKit` and `VPhoneVMKit`. Consumers such as
`vphone-ui` must update their package product/import references when taking
this version. CLI command names (`vm`, `fw`, `cfw`), option names, socket paths,
and guest JSON keys remain unchanged. Recognizable technical names such as
`API`, `HTTP`, `APFS`, `AEA`, `IPSW`, `TXM`, `MachO`, and kernel symbol spellings
remain abbreviated.

## Shared Kit decision

The useful extraction is a **guest API protocol** module. The public
`VPhoneAPIKit` client owns typed `VPhoneJSONValue`, response and event models;
the VM's direct `VPhoneGuestControl` and iOS `vphoned` each encode or decode the
same `/v1/rpc` envelope with `[String: Any]`. A shared Foundation-only target
should own request, response, error, and event envelopes and their validation.
The URLSession, VSOCK, and SwiftNIO transports would remain with their current
owners. The guest dispatcher and its IcliKit/native operations remain in
`vphoned`.

The extraction needs a coordinated wire migration and JSON compatibility tests
for both macOS and iOS before becoming a useful Kit. Moving the public model
alone would leave the duplicated decoders intact. No new shared target was
added in this naming pass. `VPhoneCore` also has broad contents, but its
firmware selection and bundle operations do not yet have a common external
consumer that justifies another public framework.

## Dependency cleanup

`VPhoneVirtualMachineKit` no longer declares unused direct dependencies on
`VPhoneAPIKit` and `ArgumentParser`; the root and guest packages no longer
declare unused direct `swift-collections` dependencies. Their transitive
dependencies remain owned by the packages that use them.

## Verification

- `swift test --jobs 4`: 340 tests in 74 suites passed.
- `zsh Scripts/build.sh`: host binaries, signed app, and iOS guest built.
- `zsh Scripts/check_aux.sh`: all admission gates passed.
- `vphone-cli --help`: public `vm`, `fw`, and `cfw` command names remain present.
