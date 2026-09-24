# Sibling guest components

`make -C VPhoneGuestComponents package` cross-compiles guest components with
Xcode's iPhoneOS SDK. The archive contains signed arm64e binaries, two camera
tweak filter plists, and the GPU provenance note:

| Component | Archive contents |
| --- | --- |
| Camera app hook | `camfix/libcamfix.dylib`, `camfix/libcamfix.plist` |
| Camera daemon hook | `vcamcaptured/libvcamcaptured.dylib`, `vcamcaptured/libvcamcaptured.plist` |
| Launchd hook | `launchhook/launchdhook-vphone.dylib` |
| Reserved process hook | `systemhook/SystemHook-vphone.dylib` |
| PCC GPU driver | `gpu/README.md` (source and extraction flow; no Apple binary) |

The archive is a local build artifact, not a VM bootstrap. The launchd hook is
installed by `cfw install` to discover package daemons after reboot; the process
hook is staged but has no injection or chain-load behavior yet. Irisin installs
ElleKit's own `TweakLoader.dylib` in the selected bootstrap. The required GPU bundle is
instead extracted from the selected PCC firmware by `vphone-cli fw prepare`
and copied into the VM during JB installation. No Apple GPU binary is stored
in this directory, the archive, or the shipped app.

See `Research/Guest/virtual_camera_transport.md` for the camera transport
validation and the hook installation prerequisites.
