# Optional sibling components

`make siblings_package` (or `make -C siblings package`) cross-compiles the
four optional guest components with Xcode's iPhoneOS SDK and writes
`.build/siblings/siblings.tar`. The archive contains signed arm64e binaries and
the two tweak filter plists:

| Component | Archive contents |
| --- | --- |
| Camera app hook | `camfix/libcamfix.dylib`, `camfix/libcamfix.plist` |
| Camera daemon hook | `vcamcaptured/libvcamcaptured.dylib`, `vcamcaptured/libvcamcaptured.plist` |
| Tweak loader | `tweakloader/TweakLoader.dylib` |
| iOS 27 app registrar | `vpregister/vpregister` |

This is a build artifact, not a VM bootstrap. The normal JB build and install
flow does not stage or install these components. The GPU component is handled
separately until its firmware-derived build flow is integrated here; no Apple
GPU driver is stored in this directory.
