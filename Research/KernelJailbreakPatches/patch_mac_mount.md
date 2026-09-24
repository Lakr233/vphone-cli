# B11 `patch_mac_mount` (`2026-03-06` rework)

## Verdict

- Final result: **match upstream** `/Users/qaq/Desktop/patch_fw.py`.
- Upstream reference patches the PCC 26.1 research kernel at:
  - `0xFFFFFE0007CA9D54` / file offset `0x00CA5D54`
  - `0xFFFFFE0007CA9D88` / file offset `0x00CA5D88`
- Reworked runtime matcher now lands on those same two sites again.
- Previous local drift to `0xFFFFFE0007CA8EAC` / `0x00CA4EAC` is now treated as **wrong for this patch**: that site is inside the lower `prepare_coveredvp()` helper and corresponds to the ownership / `EPERM` gate, not the upstream mount-role wrapper gate.

## Anchor class

- Primary runtime anchor class: **string anchor**.
- String used: `"mount_common()"`.
- Why this anchor: it is present in the same VFS syscall compilation unit on the stripped PCC kernels, survives the empty embedded symtable case (`0 []`), and gives a stable way to recover the local `mount_common` function without IDA names or external symbol dumps.
- Secondary discovery after the string anchor: **semantic control-flow search** over nearby callers of the recovered `mount_common` function.

## Where the patch lands

### Site 1 — preboot-role reject gate

- Match site: `0xFFFFFE0007CA9D54` / `0x00CA5D54`
- Stock instruction: `tbnz w28, #5, ...`
- Patched instruction: `nop`
- Upstream relation: **exact match** to `/Users/qaq/Desktop/patch_fw.py` `patch(0xCA5D54, 0xD503201F)`.

### Site 2 — role-state byte gate

- Match site: `0xFFFFFE0007CA9D88` / `0x00CA5D88`
- Stock instruction: `ldrb w8, [x8, #1]`
- Patched instruction: `mov x8, xzr`
- Upstream relation: **exact match** to `/Users/qaq/Desktop/patch_fw.py` `patch(0xCA5D88, 0xAA1F03E8)`.

## Why these are the correct semantic gates

## Facts from IDA MCP on PCC 26.1 research

- The `mount_common()` string xref recovers the main mount flow function at `0xFFFFFE0007CA7868`.
- The upstream-matching wrapper candidate is a nearby caller that itself calls back into that `mount_common` function.
- In that wrapper, the first patch site is the sequence:
  - `tbnz w28, #5, loc_fail`
  - then, on the fail target, `mov w25, #1 ; b ...`
- In `research/reference/xnu/bsd/sys/mount_internal.h`, bit `0x20` is `KERNEL_MOUNT_PREBOOTVOL`.
- In the same wrapper, the second patch site is the sequence:
  - `add x8, x16, #0x70`
  - `ldrb w8, [x8, #1]`
  - `tbz w8, #6, loc_continue_to_mount_common`
  - `orr w8, w28, #0x10000`
  - `tbnz w28, #0, ...`
  - `mov w25, #1`
- The `tbz w8, #6` target flows into the block that calls back into the recovered `mount_common` function.

## Source-backed interpretation

- Fact: `KERNEL_MOUNT_PREBOOTVOL` is bit 5 in `mount_internal.h`.
- Inference: the first gate is the early Preboot-volume reject path in the mount-role wrapper; NOPing it matches the known-to-work upstream behavior.
- Fact: the second gate tests a byte-derived bit before the wrapper continues into the `mount_common` call path.
- Inference: forcing that loaded byte to zero reproduces the upstream intent of always taking the stock `tbz ..., #6, continue` path.
- Because both patched sites are in the wrapper that selects whether execution can even reach `mount_common`, they are a better semantic fit for `patch_mac_mount` than the previously drifted lower helper branch.

## Why the previous local drift was rejected

- Previous local matcher patched `0xFFFFFE0007CA8EAC` / `0x00CA4EAC`.
- IDA + XNU correlation shows that sequence belongs to the lower `prepare_coveredvp()` helper.
- That helper sequence matches the source shape of the ownership / `EPERM` preflight:
  - `vnode_getattr(...)`
  - compare owner uid vs credential uid / root
  - on failure set `W0 = 1`
- That is **not** the same gate as the upstream B11 design target.
- Since `/Users/qaq/Desktop/patch_fw.py` is known-to-work and the upstream sites still exist on PCC 26.1 research, keeping the drift would be a red flag; the rework therefore restores upstream semantics.

## Runtime matcher design

- Step 1: recover `mount_common` via the `"mount_common()"` string anchor.
- Step 2: scan only a local window around that function for callers that branch-link into it.
- Step 3: among those callers, require the unique paired shape:
  - a `tbnz <flags>, #5 -> mov #1` reject gate, and
  - a later `add ..., #0x70 ; ldrb ; tbz #6 -> block that calls mount_common` gate.
- Step 4: patch exactly those two instructions.

## Why this should generalize to PCC 26.1 release / likely 26.3 release

- It does not depend on IDA names, embedded symbols, or fixed addresses.
- The primary anchor is a diagnostic string already used elsewhere in the same VFS syscall unit and expected to survive stripped release kernels.
- The secondary matcher keys off stable semantics from XNU source and local control flow:
  - `KERNEL_MOUNT_PREBOOTVOL` bit test,
  - the nearby role-state byte test,
  - and the wrapper-to-`mount_common` call relationship.
- This is more likely to survive research vs release layout drift than the previous shallow “first callee with `bl ; cbnz w0`” heuristic.

## Performance notes

- Runtime cost stays bounded:
  - one string lookup,
  - one local scan window around the recovered `mount_common` function,
  - semantic inspection of only the small set of nearby caller functions.
- It avoids whole-kernel heuristic sweeps and does not require expensive external symbol processing.

## Focused dry-run (`2026-03-06`)

- Kernel: extracted PCC 26.1 research raw Mach-O `/tmp/vphone-kcache-research-26.1.raw`
- Result: `method_return=True`
- Emitted writes:
  - `0x00CA5D54` — `NOP [___mac_mount preboot-role reject]`
  - `0x00CA5D88` — `mov x8, xzr [___mac_mount role-state gate]`
- Upstream comparison: **exact offset match** with `/Users/qaq/Desktop/patch_fw.py`.

## 2026-03-06 Rework

- Upstream target (`/Users/qaq/Desktop/patch_fw.py`): `match`.
- Final research sites: `0x00CA5D54` (`0xFFFFFE0007CA9D54`) and `0x00CA5D88` (`0xFFFFFE0007CA9D88`).
- Anchor class: `mixed string+heuristic`. Runtime reveal uses the stable `"mount_common()"` string only to bound the surrounding `vfs_syscalls.c` neighborhood, then picks the unique nearby function that contains both upstream local gates: the early `tbnz wFlags,#5` branch and the later `add xN,#0x70 ; ldrb wN,[xN,#1] ; tbz wN,#6` policy-byte test.
- Why these sites: they are the exact upstream dual-site bypass. The earlier drift to `0x00CA4EAC` patched a different `cbnz w0` gate in another helper and is therefore rejected as an upstream mismatch.
- Release/generalization rationale: the string keeps the search local to the right source module, while the paired semantic patterns identify the same function without relying on symbols. That combination should survive 26.1 release / likely 26.3 release better than a raw offset.
- Performance note: one string anchor plus a bounded neighborhood scan (~`0x9000` bytes) instead of a whole-kernel semantic walk.
- Focused PCC 26.1 research dry-run: `hit`, 2 writes at `0x00CA5D54` and `0x00CA5D88`.
