# Sibling guest components

`make -C VPhoneGuestComponents package` cross-compiles guest components with
Xcode's iPhoneOS SDK. The archive contains signed arm64e binaries, two camera
tweak filter plists, and the GPU provenance note:

| Component | Archive contents |
| --- | --- |
| Camera app hook | `camfix/libcamfix.dylib`, `camfix/libcamfix.plist` |
| Camera daemon hook | `vcamcaptured/libvcamcaptured.dylib`, `vcamcaptured/libvcamcaptured.plist` |
| CoreLocation app hook | `locationfix/libvlocation.dylib` |
| Launchd hook | `launchhook/launchdhook-vphone.dylib` |
| Process injection bridge | `systemhook/SystemHook-vphone.dylib` |
| iOS 27 app registrar | `vpregister/vpregister` |
| PCC GPU driver | `gpu/README.md` (source and extraction flow; no Apple binary) |

The archive is a local build artifact, not a VM bootstrap. `cfw install` places
the launchd hook, SystemHook, camera hooks, and location hook in `/usr/lib`, and the
vphoned environment update replaces changed copies in a running guest. SystemHook
loads `libvcamcaptured.dylib` into `/usr/libexec/cameracaptured` and
`libcamfix.dylib` into apps that have AVFoundation loaded; neither camera hook
needs ElleKit or a bootstrap. After a bootstrap installs ElleKit, the launchd hook
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
SystemHook also loads `libvlocation.dylib` into newly started apps. When
`/var/mobile/Library/Caches/vphone-location.json` exists, the hook supplies its
coordinate through `CLLocationManager` for authorized clients. A missing state
file leaves native location in place. Apps already running when the library is
installed must be relaunched to load it.
Irisin installs ElleKit's own `TweakLoader.dylib` in the selected bootstrap.
The required GPU bundle is extracted from the selected PCC firmware by
`vphone-cli fw prepare` and copied into the VM during JB installation. No
Apple GPU binary is stored in this directory, the archive, or the shipped app.

See `Research/Guest/virtual_camera_transport.md` for the camera transport
validation and the hook installation prerequisites.
