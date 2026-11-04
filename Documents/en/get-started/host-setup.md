# Host Setup

Prepare your Mac so it can run the entitled VM process, `vphone-vm`. Do this once per Mac, and repeat the allowlist step whenever the `vphone-vm` signature changes.

You need an Apple Silicon Mac running macOS 15 or newer. PV=3 research guests do not run inside a nested macOS VM.

## Check the host

Run the preflight from the `VPhone.bundle` you use:

```sh
vphone-cli host preflight
```

It checks the entitled `vphone-vm` before any VM starts. If AMFI refuses `vphone-vm`, the error prints the exact `sudo .../vphone-escalator allow .../vphone-vm` command for that bundle.

## Choose a security configuration

`vphone-vm` carries Apple-private virtualization entitlements, so macOS must accept it. Both options below need Research Guests enabled in Recovery. Choose one.

### Option A: Keep SIP enabled with debugging restrictions relaxed

1. Boot into macOS Recovery, open Terminal, and run:

   ```sh
   csrutil enable --without debug
   csrutil allow-research-guests enable
   ```

2. Restart into macOS.
3. Allowlist the current `vphone-vm`. With a distributed bundle, run `vphone-cli host preflight` and run the command it prints. From a source checkout:

   ```sh
   bundle=.build/XcodeBundle/Build/Products/Debug/VPhone.bundle
   sudo "$bundle/Contents/MacOS/vphone-escalator" allow "$bundle/Contents/MacOS/vphone-vm"
   "$bundle/Contents/MacOS/vphone-escalator" status
   "$bundle/Contents/MacOS/vphone-cli" host preflight
   ```

> [!WARNING]
> Repeat the `allow` command after every build, including a rebuild that only changes the signature. The allowlist holds the `vphone-vm` cdhash, and a new signature has a new one.

To undo the allowlist:

```sh
sudo "$bundle/Contents/MacOS/vphone-escalator" off
```

`off` removes only the hashes `vphone-escalator` added and restarts amfid. It keeps the preference and its other values.

You can pass more signed host binaries to the same `allow` command when they need restricted entitlements. The unentitled `vphone-cli` does not need it.

### Option B: Disable SIP and AMFI

This is the more permissive configuration.

1. Boot into macOS Recovery, open Terminal, and run:

   ```sh
   csrutil disable
   csrutil allow-research-guests enable
   ```

2. Restart into macOS, set the boot argument, and restart again:

   ```sh
   sudo nvram boot-args="amfi_get_out_of_my_way=1 -v"
   ```

> [!WARNING]
> This replaces any existing `boot-args`. Check them with `nvram boot-args` first.

## With Launchpad

Launchpad's bundle preflight checks that SIP debugging restrictions are disabled (or SIP is fully disabled) and that Research Guests is enabled. You do not run `vphone-escalator` yourself:

- If AMFI blocks the installed `vphone-vm`, Launchpad's helper checks those host settings again, verifies the root-owned bundle and its recorded cdhash, runs that bundle's `vphone-escalator allow` as root, and Launchpad repeats preflight.
- Each new bundle signature is checked and allowed separately.
- When a newer Launchpad includes a newer helper, it asks for administrator authorization to update the helper at startup.

The standalone `vphone-cli` still reports the manual command.

## Build from source

A distributed `VPhone.bundle` needs no Homebrew, Python, or Xcode at runtime. Building from source needs Xcode and its iPhoneOS SDK, which compiles `vphoned`. From a checkout:

```sh
xcodebuild -workspace VPhone.xcworkspace -scheme VPhone \
  -configuration Debug -destination 'platform=macOS,arch=arm64' \
  -derivedDataPath .build/XcodeBundle build
.build/XcodeBundle/Build/Products/Debug/VPhone.bundle/Contents/MacOS/vphone-cli host preflight
```

The `VPhone` scheme produces the ad hoc signed bundle with all its programs. With Option A, allowlist each new build.

## What the allowlist changes

`vphone-escalator allow` creates the AMFI code-requirements preference if it is absent. If it exists, it appends the current `vphone-vm` cdhash to its `Entitlements` requirement, keeping other cdhashes and preference keys, and skips hashes already there. It leaves an existing `AllowUnsafeDynamicLinking` value untouched and writes `false` only when that key is absent. It makes amfid consult the requirement by changing one byte in amfid's heap.

## What the bundle contains

- `vphone-cli` orchestrates the work without private entitlements and handles archives through `vphone-cli archive`.
- `vphone-vm` is the signed, entitled VM and window process.
- `vphoned` is compiled for iOS at build time and installed into each created guest.

For the implementation history, see the [research notes on the binary split](../../../Research/Host/host_binary_split.md).

## See also

- [Quick Start](quick-start.md)
- [Create and Run a VM](../machines/create-and-run.md)
- [Troubleshooting](../help/troubleshooting.md)
