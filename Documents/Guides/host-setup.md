# Host setup

[Documentation](../README.md) · [Create a VM](create-and-run.md) · [Troubleshooting](troubleshooting.md)

The VM needs an Apple Silicon Mac running macOS 15 or newer. PV=3 research guests do not run inside a nested macOS VM. The signed `vphone-vm` companion carries Apple-private virtualization entitlements; the unentitled `vphone-cli` entry point can still print a useful error if the host refuses it.

## Build and preflight

A distributed `.bundle` needs no Homebrew, Python or Xcode **at runtime**. A source build needs Xcode and its iPhoneOS SDK to compile vphoned. From a source checkout:

```sh
xcodebuild -workspace VPhone.xcworkspace -scheme VPhone \
  -configuration Debug -destination 'platform=macOS,arch=arm64' \
  -derivedDataPath .build/XcodeBundle build
.build/XcodeBundle/Build/Products/Debug/VPhone.bundle/Contents/MacOS/vphone-cli host preflight
```

Build the `VPhone` scheme in Xcode to produce the ad hoc signed bundle with all companion binaries. `host preflight` checks the entitled companion before any VM is started. If AMFI refuses it, the error prints the bundled allowlist helper command.

## Permit the entitled VM binary

These are host policy choices, performed by the machine owner. Both require `csrutil allow-research-guests enable` in Recovery. Choose one path.

### A. Disable SIP and AMFI

In macOS Recovery, open Terminal:

```sh
csrutil disable
csrutil allow-research-guests enable
```

After rebooting into macOS, set the boot argument and reboot again:

```sh
sudo nvram boot-args="amfi_get_out_of_my_way=1 -v"
```

This is the more permissive host configuration. Review existing `boot-args` before replacing them.

### B. Keep SIP enabled with debugging restrictions relaxed

In macOS Recovery:

```sh
csrutil enable --without debug
csrutil allow-research-guests enable
```

After rebooting, allowlist the **current signed build**. In a source checkout:

```sh
bundle=.build/XcodeBundle/Build/Products/Debug/VPhone.bundle
sudo "$bundle/Contents/MacOS/VPhoneEscalator" allow "$bundle/Contents/MacOS/vphone-vm"
"$bundle/Contents/MacOS/VPhoneEscalator" status
"$bundle/Contents/MacOS/vphone-cli" host preflight
```

The helper creates the AMFI code-requirements preference if absent. If it exists, it appends the current `vphone-vm` cdhash to its `Entitlements` requirement, preserving other cdhashes and preference keys. It leaves any existing `AllowUnsafeDynamicLinking` value untouched and writes `false` only when that key is absent. It avoids duplicate hashes and enables amfid to consult the requirement by changing one byte in its heap. **Repeat the `allow` command after every build**, including a rebuild that only changes the signature. You may pass additional signed host binaries to the same `allow` command when they need restricted entitlements; the unentitled `vphone-cli` does not need this. `sudo "$bundle/Contents/MacOS/VPhoneEscalator" off` removes only hashes added by this helper and restarts amfid. It preserves the preference and its other values.

For a distributed bundle without a source checkout, run `vphone-cli host preflight` first. If AMFI refuses the guest, its error gives the full `sudo .../VPhoneEscalator allow .../vphone-vm` command for that bundle.

## What the build contains

`vphone-cli` orchestrates the work without private entitlements and handles archives through `vphone-cli archive`. `vphone-vm` is the signed, entitled GUI/VM process. The bundle also contains `vphoned`, compiled for iOS at build time; it is installed into each created guest. The [research notes on the binary split](../../Research/Host/host_binary_split.md) record the implementation history, including superseded approaches.
