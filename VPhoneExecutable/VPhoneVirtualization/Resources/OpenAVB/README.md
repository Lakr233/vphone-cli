# OpenAVB

`OpenAVB.bin` is the boot ROM new machines run instead of Apple's
`AVPBooter.vresearch1.bin`. It is
[OpenAVB](https://github.com/owngoal-dev/OpenAVB), an open-source AArch64
boot ROM compatible with AVPBooter, built from source. `StageBundle.sh` copies
the image and its licenses to `VPhone.bundle/Contents/Resources/OpenAVB/`, and `vm new` copies
the image into each new machine folder.

| | |
| --- | --- |
| Source | `https://github.com/owngoal-dev/OpenAVB` |
| Commit | `65a776e9ae00b2e1de22b18cbbad1359945d7277` |
| Patches | `0001-entropy-descriptor-set-has-data.patch` (`patches/*.patch`, applied in order) |
| Target | `make build/OpenAVB.bin` |
| Toolchain | Homebrew LLVM 23.1.3 (`clang`, `llvm-objcopy`), Homebrew LLD 23.1.3 |
| SHA-256 | `35793a60f35beade7bef5b845fa207265cbe82f41f45ce8b56a109e999e71eb3` |
| Size | 460057 bytes |

The image is checked in rather than built by the `VPhone` scheme, so building
the bundle needs no cross toolchain. To move to another commit, or to check
that this file is what the commit builds, run
`VPhoneExecutable/VPhoneVirtualization/Build/UpdateOpenAVB.sh` (see its
header). It clones and builds outside the repository and needs
`brew install llvm lld`.

## Patches

`0001-entropy-descriptor-set-has-data.patch` lets an iOS 27 LLB boot. The
ROM hands LLB its entropy request over the descriptor transport, which has a
fifth operation, SET_HAS_DATA, that marks a written request as holding data.
AVPBooter sends it after every write; OpenAVB did not. LLB up to iOS 26 read
the request without asking, but the iOS 27 LLB asks HAS_DATA first, finds
nothing, and panics (`iBoot Panic: …:73`). With the patch, a 27.2 LLB logs the
same lines as under AVPBooter and the kernel boots. Not upstream yet.

Earlier changes are all upstream. OpenAVB's first commit, `54b67bf`, did not run under
Virtualization.framework. Five changes found on live machines made it boot and
restore, and upstream took them in
[owngoal-dev/OpenAVB#1](https://github.com/owngoal-dev/OpenAVB/pull/1), now
part of `115169e`. A sixth let a guest reboot: after a reboot the SEP restarts
together with the ROM, a request sent before it was up was dropped, and every
reboot hung, so the ROM now waits for the SEP's first message before sending.
Upstream took it in
[owngoal-dev/OpenAVB#2](https://github.com/owngoal-dev/OpenAVB/pull/2). A
seventh lets a guest with less than about 7.5 GiB of memory boot: the ROM
published the LLB manifest digest into the t8110 SIDP block at `0x2_3D2E_0044`,
which Virtualization.framework does not back there, and now skips it when the
chip ID register reads 0. Upstream took it in
[owngoal-dev/OpenAVB#3](https://github.com/owngoal-dev/OpenAVB/pull/3). The pin
is that PR's head, `65a776e`, which `main` reaches through the merge `234a080`
(same tree), rather than the merge itself.
`Research/Firmware/openavb_boot_rom.md` has the evidence for each change.

If vphone needs a change upstream has not taken yet, put it in `patches/` as a
`git format-patch` file. `UpdateOpenAVB.sh` applies patches in order and
refuses one that no longer applies. Delete a patch once the pin moves past it.

## License

`LICENSE` is OpenAVB's license as published at that commit: MIT for OpenAVB's
own code, with the third-party notices it lists. A few files built into the
image are APSL-2.0 (`APSL-2.0.txt`); their modified source is the public
repository above.

What the ROM expects from the host (the patch store, the stage-0 image
identity uploaded before iBSS, LZFSE payloads) is described in
`Research/Firmware/openavb_boot_rom.md`.
