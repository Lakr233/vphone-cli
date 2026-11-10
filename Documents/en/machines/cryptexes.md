# Cryptexes

A cryptex is a signed disk image that the guest mounts while it runs, with a trust cache for the programs in it. Use one to run your own programs in a `minimal` guest without restoring it again.

## Before you start

- Create the machine with the `minimal` preset and the **Trusted darwinOS environment** box on, on New Machine's Patches page. With `vphone-launchpad-cli`, that is `--preset minimal --allow filesystem-exp-trusted_darwinos`. The box takes effect only with a restore: turning it on for an existing machine means creating it again.
- Install the macOS Security Research tools (the PCC Virtual Research Environment). The VM window builds cryptexes with their `/System/Library/SecurityResearch/usr/bin/cryptexctl.research`.
- The guest needs network. Installing a cryptex asks Apple's signing server to personalize it for this guest.

In this environment the guest enforces Restricted Execution Mode, and a guest on a research-board cloudOS (26.5 to 26.7) cannot turn on Developer Mode.

## Install a cryptex

1. Put the files the cryptex holds in a folder, laid out as they appear in the cryptex. For example:

   ```
   mycryptex/
     usr/bin/server
     Library/LaunchDaemons/server.plist
   ```

   Sign each program ad hoc with the entitlements it needs (`codesign -s - --entitlements entitlements.plist usr/bin/server`).
2. In the VM window, choose **Apps › Install Cryptex…** and select that folder.

The VM window builds the cryptex for this guest, uploads it, and the guest personalizes and installs it. The folder's name, without its extension, becomes the cryptex's identifier. It is mounted at `/private/var/DarwinDataCenterSupportImage/<identifier>`, so for the folder `mycryptex` above, `usr/bin/server` is `/private/var/DarwinDataCenterSupportImage/mycryptex/usr/bin/server` in the guest. The alert after the install names the path. Launch daemons in the cryptex's `Library/LaunchDaemons` are started from it.

**Apps › List Cryptexes** shows what is installed, with each cryptex's mount point.

Several cryptexes can be installed at once, each at its own path. A folder whose name is already installed as a cryptex is refused: uninstall that cryptex first with `cryptex.uninstall` (see below), or rename the folder.

## Choose the folder, not a `.cxbd`

Install Cryptex… also takes a `.cxbd` and installs it as it is, but only one made for this guest: a Cryptex1 cryptex for the vresearch101 board, as `cryptexctl.research create` makes it with `--BORD=0x90 --CHIP=0xfe01`. Choose the folder in every other case.

A cryptex built for a Security Research Device iPhone does not install. `cryptexctl create --research`, which the SRD examples and their Makefiles use, makes that kind. Install Cryptex… names it and stops before uploading. Choose the folder it was built from instead; with a Makefile, that is often `build/<identifier>.root`, the folder whose contents went into the disk image.

## From a script

vphoned offers `cryptex.list`, `cryptex.install` and `cryptex.uninstall` through the [Automation API](automation-api.md). `cryptex.install` takes a `.cxbd` already uploaded under `/var/mobile/Documents/vphone-cryptexes` and the variant it was created with.

For the implementation, see [`Research/Firmware/trusted_darwinos_cryptexes.md`](../../../Research/Firmware/trusted_darwinos_cryptexes.md).
