# macOS 27 / Apple M6 AMFI host notes

On Apple M6 with macOS 27.0 (26A428), `amfid` runs as `ARM64E.X1` rather than the plain `arm64e` slice. The AMFI framework's shared-cache addresses differ between those architecture variants.

`VPhoneEscalator` derives the `AMFIRequirementsManager` singleton slot from its own copy of `+[AMFIRequirementsManager sharedManager]`, then reads the same slot in `amfid`. A plain-arm64e escalator therefore derives the wrong shared-cache slot when `amfid` is X1. The failure presents as an invalid remote pointer such as `0x73db0000ffffffff` and `mach_vm_read_overwrite` returns `KERN_INVALID_ADDRESS`.

The supported build fix is to ship `vphone-escalator` as a fat Mach-O containing both `arm64e` and `arm64e.x1`. dyld then selects the architecture variant matching the host, so the slot derivation uses the same shared-cache layout as `amfid`.

The escalator also strips pointer-authentication/tag bits from the remote singleton pointer using `machdep.virtual_address_size`, matching the upstream `Lakr233/amfi-allow` fix merged in PR #1 (`strip-pac-vm-reads`).

## Validation on M6

1. Confirm `/usr/libexec/amfid` is reported as `ARM64E.X1` by `vmmap`/process metadata.
2. Build `VPhoneEscalator` with `ARCHS="arm64e arm64e.x1"` and `ONLY_ACTIVE_ARCH=NO`.
3. Confirm `file`/`lipo -info` report both `arm64e` and `arm64e.x1` slices.
4. Run `vphone-escalator status` as root. The singleton slot must resolve to a mapped `AMFIRequirementsManager`, its isa class bits must match, and both boolean ivars must read as 0 or 1.
5. Do not attempt the `allow` write path until the read-only status check succeeds.

This fix does not disable SIP, patch executable code in `amfid`, or change `vm.cs_system_enforcement`.

## Bundle staging

`StageBundle.sh` must not pin the Escalator build to `-destination 'platform=macOS,arch=arm64e'`: Xcode treats that destination as an active-architecture constraint and emits a thin `arm64e` executable even when the project `ARCHS` contains both variants. The staging build therefore passes `ARCHS="arm64e arm64e.x1"` and `ONLY_ACTIVE_ARCH=NO` explicitly and does not set an arm64e-only destination.
