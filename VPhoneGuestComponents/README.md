# Sibling guest components

`make -C VPhoneGuestComponents package` cross-compiles four
optional guest components with Xcode's iPhoneOS SDK and writes
`.build/siblings/siblings.tar`. The archive contains signed arm64e binaries,
two tweak filter plists, and the GPU provenance note:

| Component | Archive contents |
| --- | --- |
| Camera app hook | `camfix/libcamfix.dylib`, `camfix/libcamfix.plist` |
| Camera daemon hook | `vcamcaptured/libvcamcaptured.dylib`, `vcamcaptured/libvcamcaptured.plist` |
| Tweak loader | `tweakloader/TweakLoader.dylib` |
| PCC GPU driver | `gpu/README.md` (source and extraction flow; no Apple binary) |

The archive is a local build artifact, not a VM bootstrap. The four optional
components are not installed by the normal JB flow. The required GPU bundle is
instead extracted from the selected PCC firmware by `vphone-cli fw prepare`
and copied into the VM during JB installation. No Apple GPU binary is stored
in this directory, the archive, or the shipped app.

See `Research/Guest/virtual_camera_transport.md` for the camera transport
validation and the hook installation prerequisites.
