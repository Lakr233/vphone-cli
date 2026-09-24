# VPhone bundle integration

The `VPhone` Xcode scheme produces `VPhone.bundle`. It is a container for
executables and resources, not a macOS app or a dynamically loaded plug-in.
`vphone-workstation` should keep the bundle intact and launch
`Contents/MacOS/vphone-cli` as a process. The CLI locates its companion
`vphone-vm` by resolving its own executable path.

| Path | Role |
| --- | --- |
| `Contents/MacOS/vphone-cli` | Unentitled command entry point |
| `Contents/MacOS/vphone-vm` | VM and window process; private virtualization entitlements |
| `Contents/MacOS/VPhoneEscalator` | AMFI allowlist tool for the current VM cdhash |
| `Contents/MacOS/vphoned.signed` | Guest daemon payload with its own entitlements |
| Guest dylibs in `Contents/MacOS` | Guest installation payloads |
| `Contents/Resources` | Guest configuration and nonexecutable resources |

All executable payloads use ad hoc code signatures. Only the required child
processes carry private entitlements. The bundle has no `CFBundleExecutable`,
app launcher, SMJobBless helper, installer, password prompt, or automatic root
acquisition. The integrating application owns download, release verification,
host authorization, installation, and update policy. Developer Tools access
and AMFI authorization are separate host decisions.

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
