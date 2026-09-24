# Sibling guest components

`make -C VPhoneGuestComponents package` cross-compiles guest components with
Xcode's iPhoneOS SDK. The archive contains signed arm64e binaries, two camera
tweak filter plists, and the GPU provenance note:

| Component | Archive contents |
| --- | --- |
| Camera app hook | `camfix/libcamfix.dylib`, `camfix/libcamfix.plist` |
| Camera daemon hook | `vcamcaptured/libvcamcaptured.dylib`, `vcamcaptured/libvcamcaptured.plist` |
| Launchd hook | `launchhook/launchdhook-vphone.dylib` |
| Process injection bridge | `systemhook/SystemHook-vphone.dylib` |
| iOS 27 app registrar | `vpregister/vpregister` |
| PCC GPU driver | `gpu/README.md` (source and extraction flow; no Apple binary) |

The archive is a local build artifact, not a VM bootstrap. `cfw install` places
both hooks in `/usr/lib`. After a bootstrap installs ElleKit, the launchd hook
inserts SystemHook into `xpcproxy`, bootstrap executables, and apps started
directly by launchd. Inside `xpcproxy`, SystemHook carries itself into the
final executable through `posix_spawnp`. Injected App and bootstrap processes
carry the hook to their child executables through `posix_spawn`, `posix_spawnp`,
and `execve`. SystemHook loads the selected bootstrap's
`usr/lib/TweakLoader.dylib` in App and bootstrap processes when it exists;
ElleKit owns tweak selection and loading. It logs PID and executable path to
`/var/mobile/Library/Caches/vphone-systemhook.log`, falling back to the app's
own `Library/Caches` when sandboxed.
`DISABLE_TWEAKS=1` and the safe-mode flags skip injection.
Irisin installs ElleKit's own `TweakLoader.dylib` in the selected bootstrap.
The required GPU bundle is extracted from the selected PCC firmware by
`vphone-cli fw prepare` and copied into the VM during JB installation. No
Apple GPU binary is stored in this directory, the archive, or the shipped app.

See `Research/Guest/virtual_camera_transport.md` for the camera transport
validation and the hook installation prerequisites.
