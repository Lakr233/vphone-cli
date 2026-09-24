# Host setup

[Documentation](../README.md) · [Create a VM](create-and-run.md) · [Troubleshooting](troubleshooting.md)

The VM needs an Apple Silicon Mac running macOS 15 or newer. PV=3 research guests do not run inside a nested macOS VM. The signed `vphone-vm` companion carries Apple-private virtualization entitlements; the unentitled `vphone-cli` entry point can still print a useful error if the host refuses it.

## Build and preflight

A distributed `.app` needs no Homebrew, Python or Xcode **at runtime**. A source build needs Xcode and its iPhoneOS SDK to compile vphoned. From a source checkout:

```sh
zsh scripts/build.sh
.build/release/vphone-cli host preflight
```

Use `scripts/build.sh` rather than bare `swift build`: the latter does not perform the required signing and bundling. `host preflight` checks the entitled companion before any VM is started. If AMFI refuses it, the error prints the bundled allowlist helper command.

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
sudo .build/release/vphone-amfi-allow allow \
  .build/release/vphone-vm \
  .build/vphone-cli.app/Contents/MacOS/vphone-vm
.build/release/vphone-amfi-allow status
.build/release/vphone-cli host preflight
```

The helper records both `vphone-vm` cdhashes in the AMFI code-requirements preference and enables amfid to consult it by changing one byte in its heap. It is scoped to these signed binaries. **Repeat the `allow` command after every build**, including a rebuild that only changes the signature. Run `sudo .build/release/vphone-amfi-allow off` to remove the allowlist and restart amfid.

For a distributed app without a source checkout, run `vphone-cli host preflight` first. If AMFI refuses the guest, its error gives the full `sudo .../vphone-amfi-allow allow .../vphone-vm` command for that installed app.

## What the build contains

`vphone-cli` orchestrates the work without private entitlements. `vphone-vm` is the signed, entitled GUI/VM process. `vphone-archive` handles archives. The project also bundles vphoned, compiled for iOS at build time; it is installed into each created guest. The [research notes on the binary split](../../research/host/host_binary_split.md) record the implementation history, including superseded approaches.
