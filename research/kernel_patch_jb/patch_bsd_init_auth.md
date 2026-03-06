# B13 `patch_bsd_init_auth`

## Scope

- Kernel analyzed: `kernelcache.research.vphone600`
- Symbol handling: prefer in-image LC_SYMTAB if present; otherwise recover `bsd_init` from in-kernel string xrefs and local control-flow.
- XNU reference: `research/reference/xnu/bsd/kern/bsd_init.c`
- Analysis basis: IDA-MCP + local XNU source correlation

## Bottom Line

- Earlier B13 notes are **not trustworthy** as a patch-site guide.
- The currently documented runtime hit at `0xFFFFFE0007FB09DC` is **not inside `bsd_init`**.
- The real `bsd_init` root-auth gate is in `bsd_init` at `0xFFFFFE0007F7B988` / `0xFFFFFE0007F7B98C`.
- If B13 is re-enabled, the patch should target the **`FSIOC_KERNEL_ROOTAUTH` return check in `bsd_init`**, not the `ldr x0,[xN,#0x2b8]; cbz x0; bl` pattern currently used by the patcher.

## What This Patch Is Actually For

Fact:

- In XNU, `bsd_init()` mounts root, calls `IOSecureBSDRoot(rootdevice)`, resolves `rootvnode`, and then enforces root-volume authentication.
- The relevant source block in `research/reference/xnu/bsd/kern/bsd_init.c` is:
  - `if (!bsd_rooted_ramdisk()) {`
  - `autherr = VNOP_IOCTL(rootvnode, FSIOC_KERNEL_ROOTAUTH, NULL, 0, vfs_context_kernel());`
  - `if (autherr) panic("rootvp not authenticated after mounting");`

Inference:

- The jailbreak purpose of B13 is **not** “generic auth bypass”.
- Its real purpose is very narrow: **allow boot to continue even when the mounted root volume fails `FSIOC_KERNEL_ROOTAUTH`**.
- In practice this means permitting a modified / non-sealed / otherwise non-stock root volume to survive the early BSD boot gate.

## Real Control Flow in `bsd_init`

### Confirmed symbols and anchors

- `bsd_init` = `0xFFFFFE0007F7ADD4`
- Panic string = `"rootvp not authenticated after mounting @%s:%d"` at `0xFFFFFE000707D6BB`
- String xref inside `bsd_init` = `0xFFFFFE0007F7BC04`
- Static caller of `bsd_init` = `kernel_bootstrap_thread` at `0xFFFFFE0007B44428`

### Confirmed boot path

Fact, from IDA + XNU correlation:

1. `bsd_init` mounts root via `vfs_mountroot`.
2. `bsd_init` calls `IOSecureBSDRoot(rootdevice)` at `0xFFFFFE0007F7B7C4`.
3. `bsd_init` resolves the mounted root vnode and stores it as `rootvnode`.
4. `bsd_init` calls `bsd_rooted_ramdisk` at `0xFFFFFE0007F7B934`.
5. If not rooted ramdisk, `bsd_init` constructs a `VNOP_IOCTL` call for `FSIOC_KERNEL_ROOTAUTH`.
6. The indirect filesystem op is invoked at `0xFFFFFE0007F7B988`.
7. The return value is checked at `0xFFFFFE0007F7B98C`.
8. Failure branches to the panic/report block at `0xFFFFFE0007F7BBF4`.

### Exact IDA site

Relevant instructions in `bsd_init`:

```asm
0xFFFFFE0007F7B934  BL      bsd_rooted_ramdisk
0xFFFFFE0007F7B938  TBNZ    W0, #0, 0xFFFFFE0007F7B990

0xFFFFFE0007F7B94C  MOV     W10, #0x80046833
...
0xFFFFFE0007F7B980  ADD     X0, SP, #var_130
0xFFFFFE0007F7B984  MOV     X17, #0x307A
0xFFFFFE0007F7B988  BLRAA   X8, X17
0xFFFFFE0007F7B98C  CBNZ    W0, 0xFFFFFE0007F7BBF4
```

And the failure block:

```asm
0xFFFFFE0007F7BBF4  ADRL    X8, "bsd_init.c"
0xFFFFFE0007F7BBFC  MOV     W9, #0x3D3
0xFFFFFE0007F7BC04  ADRL    X0, "rootvp not authenticated after mounting @%s:%d"
0xFFFFFE0007F7BC0C  BL      sub_FFFFFE0008302368
```

## Why This Is The Real Site

### Source-to-binary correlation

Fact:

- `FSIOC_KERNEL_ROOTAUTH` is defined in `research/reference/xnu/bsd/sys/fsctl.h`.
- The binary literal loaded in `bsd_init` is `0x80046833`, which matches `FSIOC_KERNEL_ROOTAUTH`.
- The call setup happens immediately after `bsd_rooted_ramdisk()` and immediately before the rootvp panic string block.

Inference:

- This is the exact lowered form of:

```c
autherr = VNOP_IOCTL(rootvnode, FSIOC_KERNEL_ROOTAUTH, NULL, 0, vfs_context_kernel());
if (autherr) {
    panic("rootvp not authenticated after mounting");
}
```

### Call-stack view

Useful boot-path stack, expressed semantically rather than as a fake direct symbol chain:

- `kernel_bootstrap_thread`
- `bsd_init`
- `vfs_mountroot`
- `IOSecureBSDRoot`
- `VFS_ROOT` / `set_rootvnode`
- `bsd_rooted_ramdisk`
- `VNOP_IOCTL(rootvnode, FSIOC_KERNEL_ROOTAUTH, NULL, 0, vfs_context_kernel())`
- failure path -> panic/report block using `"rootvp not authenticated after mounting @%s:%d"`

## Why The Existing B13 Matcher Is Wrong

### Old documented runtime hit is unrelated

Fact:

- Existing runtime-verification artifacts recorded B13 at `0xFFFFFE0007FB09DC`.
- IDA resolves that site to `exec_handle_sugid`, not `bsd_init`.
- The surrounding code is:

```asm
0xFFFFFE0007FB09D4  LDR     X0, [X20,#0x2B8]
0xFFFFFE0007FB09D8  CBZ     X0, 0xFFFFFE0007FB09E4
0xFFFFFE0007FB09DC  BL      sub_FFFFFE0007B84C5C
```

- That is exactly the shape the current patcher searches for.

### Why the heuristic false-positive happened

Fact:

- `scripts/patchers/kernel_jb_patch_bsd_init_auth.py` looks for:
  - `ldr x0, [xN, #0x2b8]`
  - `cbz x0, ...`
  - `bl ...`
- It then ranks candidates by:
  - neighborhood near a `bsd_init` string anchor,
  - presence of `"/dev/null"` in the function,
  - low caller count.

Fact:

- `exec_handle_sugid` also references `"/dev/null"` in the same function.
- Therefore the heuristic can promote `exec_handle_sugid` even though it is semantically unrelated to root-volume auth.

Conclusion:

- The current B13 implementation is not “slightly off”; it is targeting the wrong logical site class.
- This explains why enabling B13 can break boot: it mutates an exec/credential path instead of the early root-auth gate.

## Correct Patch Candidate(s)

### Preferred candidate: patch the return check, not the call target

Patch site:

- `0xFFFFFE0007F7B98C` in `bsd_init`
- instruction: `CBNZ W0, 0xFFFFFE0007F7BBF4`

Recommended transform:

- before: `40 13 00 35`
- after: `1F 20 03 D5` (`NOP`)

Effect:

- `VNOP_IOCTL(... FSIOC_KERNEL_ROOTAUTH ...)` still executes.
- Only the early boot failure gate is removed.
- This is the narrowest behavioral change that matches the XNU source intent.

### Secondary candidate: force the ioctl result to success

Patch site:

- `0xFFFFFE0007F7B988` in `bsd_init`
- instruction: `BLRAA X8, X17`

Possible transform:

- before: `11 09 3F D7`
- after: `00 00 80 52` (`MOV W0, #0`)

Effect:

- Skips the actual filesystem ioctl implementation entirely.
- More invasive than patching the subsequent `CBNZ`.

Assessment:

- If we need a first retest candidate, `NOP`-ing `CBNZ W0` is safer than replacing the call.
- It preserves any filesystem side effects that happen during the auth ioctl and only suppresses the panic gate.

## What The Patch Does After It Is Correctly Retargeted

- Allows the system to continue booting even if the mounted root volume is not accepted by `FSIOC_KERNEL_ROOTAUTH`.
- Helps jailbreak-style boot flows where the root volume is intentionally modified and would otherwise fail the sealed/authenticated-root policy.
- Does **not** by itself disable MACF, AMFI, persona checks, syscall masks, or other post-boot kernel policy gates.
- In other words: B13 is a **boot-enablement patch**, not a whole-jailbreak patch.

## Risk Notes

- This patch intentionally weakens authenticated-root enforcement during early boot.
- The most likely safe form is to skip only the panic branch.
- If downstream code later depends on rootauth state beyond this early gate, more work may still be required elsewhere; this document does **not** claim B13 alone is sufficient for a full JB boot.

## Recommended Retargeting Rule (Design Only, No Code Change Landed)

If B13 is reimplemented, the matcher should anchor on facts unique to this site:

1. Resolve `_bsd_init` / `bsd_init` first.
2. Stay inside that function only.
3. Find the post-`bsd_rooted_ramdisk` false path.
4. Require the literal `0x80046833` (`FSIOC_KERNEL_ROOTAUTH`) in the setup block.
5. Require the next call to be the indirect vnode-op call.
6. Patch the following `CBNZ W0, panic_block`.
7. Optionally verify the failure target reaches the rootvp-auth string at `0xFFFFFE0007F7BC04`.

This rule is materially stronger than the old `ldr x0,[...,#0x2b8]; cbz; bl` shape and should exclude `exec_handle_sugid` entirely.

## Validation Status

- Validation note: on the current reference IM4P kernel, in-image symbol resolution returns `0` symbols, so B13 is currently found by anchor recovery rather than external symbol data.
- In-memory validation against `/Users/qaq/Documents/Firmwares/PCC-CloudOS-26.3-23D128/kernelcache.research.vphone600` succeeds after IM4P decompression.
- `KernelJBPatcher._build_method_plan()` now includes `patch_bsd_init_auth`.
- Live patch hit: `0xFFFFFE0007F7B98C` / file offset `0x00F7798C` / `CBNZ W0, panic` -> `NOP`.
- Historical false-positive hit `0xFFFFFE0007FB09DC` is no longer selected.

## Implementation Status

- Landed in `scripts/patchers/kernel_jb_patch_bsd_init_auth.py`.
- Default JB schedule re-enabled in `scripts/patchers/kernel_jb.py`.
- Implemented form: patch the in-function `CBNZ W0, panic` gate in `bsd_init`.
- Capstone semantic checks only: no raw-offset targeting and no operand-string/literal hardcoding in the final matcher.

## Confidence

- Confidence that `0xFFFFFE0007F7B988` / `0xFFFFFE0007F7B98C` is the real B13 site: **high**.
- Confidence that `0xFFFFFE0007FB09DC` is a false-positive site: **high**.
- Confidence that `NOP CBNZ` is a better first retest than `MOV W0,#0` on the call: **medium**, because APFS-side behavior is closed-source and may have side effects not visible from XNU alone.
