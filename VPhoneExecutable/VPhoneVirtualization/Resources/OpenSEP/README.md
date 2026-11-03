# OpenSEP

`OpenSEP.bin` is the SEP boot ROM new machines run instead of Apple's
`AVPSEPBooter.vresearch1.bin`. It is
[OpenSEP](https://github.com/owngoal-dev/OpenSEP), an open-source SEP boot ROM
compatible with AVPSEPBooter, built from source for the `vresearch1` platform.
`StageBundle.sh` copies the image and its license to
`VPhone.bundle/Contents/Resources/OpenSEP/`, and `vm new` copies the image into
each new machine folder.

| | |
| --- | --- |
| Source | `https://github.com/owngoal-dev/OpenSEP` |
| Commit | `8b1633f7e6606f0bc9e1422c93e8d2e056154d2f` |
| Patches | `patches/*.patch`, applied in order (none) |
| Target | `make PLATFORM=vresearch1 build/OpenSEP.bin` |
| Toolchain | Homebrew LLVM 23.1.3 (`clang`, `llvm-objcopy`), Homebrew LLD 23.1.3 |
| SHA-256 | `92690b9c7e900ec0054271dbbc0444ee2d8567c8d41d3a2e491ba011e2b08b12` |
| Size | 147512 bytes (the SEP ROM window is `0x29000`, 167936) |

The image is checked in rather than built by the `VPhone` scheme, so building
the bundle needs no cross toolchain. To move to another commit, or to check
that this file is what the commit builds, run
`VPhoneExecutable/VPhoneVirtualization/Build/UpdateOpenSEP.sh` (see its
header). It clones and builds outside the repository and needs
`brew install llvm lld`.

## Patches

None. The initial import, `39ff3d7`, read two t8110 addresses that
Virtualization.framework backs only for a guest with about 7.5 GiB of memory
or more: the warm-boot mark at `0x2_3D2E_4804`, which stopped DFU, and the
DART at `0x2_5D2C_0000`, which broke a restore after NORData. vphone carried
both fixes until upstream took them in
[owngoal-dev/OpenSEP#1](https://github.com/owngoal-dev/OpenSEP/pull/1). The pin
is that PR's head, `8b1633f`, which `main` reaches through the merge `74b2359`
(same tree). `Research/Firmware/opensep_sep_rom.md` has the evidence.

If vphone needs a change upstream has not taken yet, put it in
`patches/` as a `git format-patch` file. `UpdateOpenSEP.sh` applies patches in
order and refuses one that no longer applies. Delete a patch once the pin
moves past it.

## License

`LICENSE` is OpenSEP's license as published at that commit: MIT. The image
also carries two pieces of public Apple data, as OpenSEP's README describes:
the Apple DDI Secure Boot Root CA - G1 certificate, and a table of published
per-build SEP firmware keys for iPhone14,4 that a `vresearch1` machine does not
use (its `vphone600` SEP firmware is not encrypted).

What the ROM expects from the host (memory map, mailbox, SEP firmware image)
and how vphone uses it is described in `Research/Firmware/opensep_sep_rom.md`.
