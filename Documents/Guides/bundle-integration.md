# VPhone bundle integration

The `VPhone` Xcode scheme produces `VPhone.bundle`. It is a container for
executables and resources, not a macOS app or a dynamically loaded plug-in.
An integrating application such as `vphone-launchpad` should keep the bundle intact and launch
`Contents/MacOS/vphone-cli` as a process. The CLI locates its companion
`vphone-vm` by resolving its own executable path.

| Path | Role |
| --- | --- |
| `Contents/MacOS/vphone-cli` | Unentitled command entry point |
| `Contents/MacOS/vphone-vm` | VM and window process; private virtualization entitlements |
| `Contents/MacOS/vphone-escalator` | AMFI allowlist tool for the current VM cdhash |
| `Contents/MacOS/libswiftCompatibilitySpan.vphone.dylib` | Swift back-deployment library for `vphone-vm` on macOS 15 |
| `Contents/Resources/guest-resources/vphoned` | Pre-signed guest daemon with its own entitlements; the bundle contains no unsigned copy |
| `Contents/Resources/guest-resources/*.dylib` | Guest libraries: launchd hook, SystemHook, camera hooks, the GPU compiler plugin, and the fixes and device adapters listed in [`VPhoneGuestComponents`](../../VPhoneGuestComponents/README.md) |
| `Contents/Resources/guest-resources/*.plist` | Guest launch daemon configuration, camera hook and MISFix filters |
| `Contents/Resources` | Localized strings; no signing script or entitlement file is shipped |

`Contents/MacOS` holds only programs that run on the Mac.
`guest-resources` holds only files installed into the guest; every Mach-O in
it is built for iOS. `ValidateBundle.sh` enforces both rules.
Launchpad refuses a bundle older than `minimumBundleComponents` (set in
`VPhoneLaunchpad/VPhoneLaunchpadShared/VPhoneLaunchpadBundleStore.swift`) and
does not load older bundle layouts. Bundle 2.1.0 added patch presets
(`fw patches`, `fw set-patches`, `fw patch --preset`) and the
`vphone-escalator` executable.

All executable payloads use ad hoc code signatures. Only the required child
processes carry private entitlements. The bundle has no `CFBundleExecutable`,
app launcher, SMJobBless helper, installer, password prompt, or automatic root
acquisition. The integrating application owns download, release verification,
host authorization, installation, and update policy. Developer Tools access
and AMFI authorization are separate host decisions.

macOS asks for a privacy permission (microphone, location) on behalf of the
responsible process and ties the grant to its code signature. When
`vphone-cli` is started with responsibility disclaimed, it becomes the
responsible process for `vphone-vm`; it is signed ad hoc, so each new bundle
build is asked again. An integrating application that starts `vphone-cli` as
an ordinary child of a process with a stable signature, without disclaiming
responsibility, gets the permission asked once. Launchpad does this with
`vphone-launchpad-launcher`, which it carries in its own `Contents/MacOS`.
macOS attributes a tool there to the enclosing app, so the prompt, the usage
description and the grant are the app's. Under the hardened runtime the app's
main executable must carry the matching resource entitlement
(`com.apple.security.device.audio-input`,
`com.apple.security.personal-information.location`); without it macOS refuses
the request without asking.

Install and update the whole bundle as one versioned unit. Do not rewrite a
signed binary in place. When `vphone-vm` changes, its cdhash changes; the
integrating application must arrange AMFI admission for the new build before
launching it. The VM library and caches stay outside `VPhone.bundle`, under
`~/.vphone` by default. Host-side VM outputs use mode `0777` so a separate
workstation process can access them, including after a root-run create.
Guest filesystem permissions inside `Disk.img` retain their own semantics.

Build and validate:

```sh
xcodebuild -workspace VPhone.xcworkspace -scheme VPhone \
  -configuration Debug -destination 'platform=macOS,arch=arm64' \
  -derivedDataPath .build/XcodeBundle build
```
