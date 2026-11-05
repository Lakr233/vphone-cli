# Instruments symbolication and the shared bundle seal

## Symptom (2026-11-05)

Issue Lakr233/vphone-cli#824: with the CoreDevice tunnel held, Time Profiler
records a guest process, but every frame is a bare address and the trace has
no binary for any of them. In the guest, DTServiceHub logs
`Device Info Service was unable to create symbolicator for PID <pid>` for every
process, SpringBoard included. A root tool in the guest that calls
`CSSymbolicatorCreateWithPid` itself succeeds, so CoreSymbolication works.

Reproduced on `duo272-hinge` (iPhone19,4, iOS 27.2 24B91020 on cloudOS 26.4,
bundle 2.15.2-local, Xcode 27.2 27B52): `xctrace record --attach SpringBoard`
exports 609 frames, none named, no `<binary>` rows. The issue's guests were
iPhone17,3 and iPad16,1 on 26.6.2 with the same log.

## Cause

DTServiceHub does not build the symbolicator. Its entitlements have no task
port access; `-[DTDeviceInfoService symbolicatorSignatureForPid:trackingSelector:]`
calls `pid_watcher_symbolicator_for_pid`, which sends `symbolicate_pid` through
`with_authorized_xpc_message` to the framework's XPC service
`com.apple.dt.instruments.dtsecurity.xpc`
(`/System/Library/PrivateFrameworks/DVTInstrumentsFoundation.framework/XPCServices/`).
That service carries `com.apple.system-task-ports*` and runs as root
(`XPCService._RoleAccount = root`). In DTServiceHub's own log every connection
to it reports `XPC_ERROR_CONNECTION_INTERRUPTED`, and it never appears in the
process list.

The guest's `/private/var/log/com.apple.xpc.launchd/launchd.log` gives the
reason, once per attempt:

```
(pid/315/com.apple.dt.instruments.dtsecurity.xpc [680]) <Error>: Service could not initialize: setup_role_account failed, error 0x4f - Inappropriate file type or format
(pid/315/com.apple.dt.instruments.dtsecurity.xpc [680]) <Notice>: xpcproxy exited due to exit(78), ran for 19ms
```

xpcproxy asks `com.apple.xpc.roleaccountd` to stage a role-account service.
xpcroleaccountd validates the bundle first and refuses it
(`logs.syslog` with `process: xpcroleaccountd`):

```
com.apple.securityd  MacOS error: -67023
com.apple.mis        unrecognized status -67023 from codesigning library
xpcroleaccountd      bundle code signature not valid: -402620415
xpcroleaccountd      pid[732]: failed: [79: Inappropriate file type or format]
```

-67023 is `errSecCSBadResource`, "invalid resource directory". The binary and
Info.plist match the IPSW, but `_CodeSignature/CodeResources` does not: the
guest's names `Info.plist`, `Localizable.loctable` and `VirtualAudio.bak`,
the resources of the VirtualAudio HAL plugin.

iOS ships every bundle that seals no resources with the same CodeResources,
and the system volume stores it once. On this guest
`com.apple.dt.instruments.dtsecurity.xpc/_CodeSignature/CodeResources` and
`/Library/Audio/Plug-Ins/HAL/VirtualAudio.plugin/_CodeSignature/CodeResources`
are the same inode with **6111 links**. In the IPSW both files are the same
2467 bytes (SHA-1 `c0c8a907e2663ee1dc33a137fbfb55f253bcf464`; iOS 18.6.2 22G100
is identical). The installer patches VirtualAudio and re-seals the plugin with
`codesign -f` on the mounted guest volume (`sealGuestBundle`), and codesign
rewrites CodeResources in place, so the plugin's new seal was written into
all 6111 bundles. Any of them whose resources are validated fails; dtsecurity
is the one Instruments needs. VirtualAudio itself keeps working because its
re-signed executable names the new seal.

## Fix

`sealGuestBundle` now gives the bundle's CodeResources and executable a file
of their own (a new inode renamed over the name) when they have more than one
link, before codesign runs, so a re-seal stays inside the bundle.

When that shared CodeResources no longer holds Apple's seal, the installer
writes it back in place, through every link. The seal is rebuilt in
`CustomFirmwareBundleSeal.empty`: Apple's build-system resource rules with
nothing sealed, serialized by Foundation, byte for byte the shipped file. It
is written only when the bundle's original executable (`<executable>.bak`, or
the executable when there is no backup) was signed over it: special slot 3 of
every CodeDirectory must be the seal's hash. Stock VirtualAudio and dtsecurity
both record `3c727b0f043e463c0227db49cef54c5567715986d08a46c98923c9bb73585e5a`,
the SHA-256 of the rebuilt seal. A guest damaged by an earlier install is
repaired by the next run that reaches the VirtualAudio step, which
`cfw update-environment` (Launchpad's Update Guest Environment) does.

The VirtualAudio step runs this before its patches, so a guest is repaired
even when a VirtualAudio patch site is not found. The plugin keeps the seal
its current executable is signed over (its own from the earlier re-seal, or
Apple's when the executable is), not the one written back for the others.

The live system volume is read-only (`EROFS` from vphoned), so the repair can
only happen with the machine stopped.

## Verified (2026-11-05)

On `duo272-hinge`, Update Guest Environment with the fixed bundle printed
`VirtualAudio.plugin/_CodeSignature/CodeResources: restored the seal 6110 other
bundles share`. After boot the shared inode holds the shipped seal (SHA-1
`c0c8a907…`, 6110 links) and the plugin has a file of its own (1 link). With
the tunnel held, `xctrace record --attach SpringBoard --time-limit 5s` exported
513 named frames and 69 `<binary>` rows (BacklightServices, BaseBoard,
AXRuntime, …), against none before. Re-binding the machine to a bundle without
the fix and updating its environment again re-sealed only the plugin: the
plugin's executable and its CodeResources agree (`fd914b46…`), the shared
inode is unchanged, and audiomxd runs.

The fixed bundle was built on `f476a4df`, before #832 taught the mute-set patch
iOS 27.2's throw, so its VirtualAudio patches found no site (`expected exactly 1
mute-set throw in the wrapper at 0x103ce0, found 0`) and the repair ran without
a re-seal: the reason it runs before the patches.

## Reveal procedure

1. Hold the tunnel (`devicectl device notification observe --device <udid> …`),
   record `xctrace record --attach SpringBoard --time-limit 3s`, and export
   `/trace-toc/run/data/table[@schema="time-profile"]`: no `<binary>` rows.
2. Capture `logs.syslog {process: "DTServiceHub"}` during a recording: the
   symbolicator line and the dtsecurity connection interruptions.
3. Pull `/private/var/log/com.apple.xpc.launchd/launchd.log` and grep
   `dtsecurity`: `setup_role_account failed, error 0x4f`.
4. Capture `logs.syslog {process: "xpcroleaccountd"}` during a recording:
   `bundle code signature not valid`.
5. Compare the bundle with `ipsw extract --files` of the restore IPSW, and read
   `NSFileSystemFileNumber`/`NSFileReferenceCount` of both CodeResources with
   `script.eval`.

DTServiceHub's call chain was read with `ipsw dyld disass` on the 24B91020
arm64e_x1 cache: `symbolicatorSignatureForPid:trackingSelector:` at
`0x260bfb2e4` (DVTInstrumentsFoundation), its `dispatch_sync` block at
`0x260bfb4d0`, `pid_watcher_symbolicator_for_pid`, `with_authorized_xpc_message`.
