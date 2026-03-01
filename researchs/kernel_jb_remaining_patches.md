# Kernel JB Remaining Patches — Research Notes

Last updated: 2026-03-01

## Overview

`scripts/patchers/kernel_jb.py` has 22 patch methods in `find_all()`. As of this writing:

- **19 PASSING**: All Group A + most Group B + some Group C patches
- **3 FAILING**: `patch_nvram_verify_permission`, `patch_thid_should_crash`, `patch_hook_cred_label_update_execve`
- **1 FIXED this session**: `patch_syscallmask_apply_to_proc` (bl_callers key bug + now passing)
- **2 FIXED prior session**: `patch_task_for_pid`, `patch_load_dylinker` (complete rewrites)

Upstream reference: `/Users/qaq/Documents/GitHub/super-tart-vphone/CFW/patch_fw.py`

Test kernel: `vm/iPhone17,3_26.1_23B85_Restore/kernelcache.release.vphone600` (IM4P-wrapped, bvx2 compressed)

Key facts about the kernel:
- **0 symbols resolved** (fully stripped)
- `base_va = 0xFFFFFE0007004000` (typical PCC)
- `kern_text = 0xA74000 - 0x24B0000`
- All offsets in `kernel.py` helpers are **file offsets** (not VA)
- `bl_callers` dict: keyed by file offset → list of caller file offsets

---

## Patch 1: `patch_nvram_verify_permission` — FAILING

### Upstream Reference

```python
# patch __ZL16verifyPermission16IONVRAMOperationPKhPKcb
patch(0x1234034, 0xd503201f)  # NOP
```

One single NOP at file offset `0x1234034`. The BL being NOPed calls memmove (3114 callers).

### Function Analysis

**Function start**: `0x1233E40` (PACIBSP)
**Function end**: `0x1234094` (next PACIBSP)
**Size**: `0x254` bytes
**BL callers**: 0 (IOKit virtual method, dispatched via vtable)
**Instruction**: `retab` at end

#### Full BL targets in the function:

| Offset | Delta | Target | Callers | Likely Identity |
|--------|-------|--------|---------|-----------------|
| 0x1233F0C | +0x0CC | 0x0AD10DC | 6190 | lck_rw_done / lock_release |
| 0x1234034 | +0x1F4 | 0x12CB0D0 | 3114 | **memmove** ← PATCH THIS |
| 0x1234048 | +0x208 | 0x0ACB418 | 423 | OSObject::release |
| 0x1234070 | +0x230 | 0x0AD029C | 4921 | lck_rw_lock_exclusive |
| 0x123407C | +0x23C | 0x0AD10DC | 6190 | lck_rw_done |
| 0x123408C | +0x24C | 0x0AD10DC | 6190 | lck_rw_done |

#### Key instructions in the function:

- `CASA` at +0x54 (offset 0x1233E94) — atomic compare-and-swap for lock acquisition
- `CASL` at 3 locations — lock release
- 4x `BLRAA` — authenticated indirect calls through vtable pointers
- `movk x17, #0xcda1, lsl #48` — PAC discriminator for IONVRAMController class
- `RETAB` — PAC return
- `mov x8, #-1; str x8, [x19]` — cleanup pattern near end
- `ubfiz x2, x8, #3, #0x20` before BL memmove — size = count * 8

#### "Remove from array" pattern (at patch site):

```
0x1233FD8: adrp x8, #0x272f000
0x1233FDC: ldr x8, [x8, #0x10]      ; load observer list struct
0x1233FE0: cbz x8, skip             ; if null, skip
0x1233FE4: ldr w11, [x8, #0x10]     ; load count
0x1233FE8: cbz w11, skip            ; if 0, skip
0x1233FEC: mov x10, #0              ; index = 0
0x1233FF0: ldr x9, [x8, #0x18]     ; load array base
  loop:
0x1233FF4: add x12, x9, x10, lsl #3
0x1233FF8: ldr x12, [x12]          ; array[index]
0x1233FFC: cmp x12, x19            ; compare with self
0x1234000: b.eq found
0x1234004: add x10, x10, #1        ; index++
0x1234008: cmp x11, x10
0x123400C: b.ne loop
  found:
0x1234014: sub w11, w11, #1        ; count--
0x1234018: str w11, [x8, #0x10]    ; store
0x123401C: subs w8, w11, w10       ; remaining
0x1234020: b.ls skip
0x1234024: ubfiz x2, x8, #3, #0x20 ; size = remaining * 8
0x1234028: add x0, x9, w10, uxtw #3
0x123402C: add w8, w10, #1
0x1234030: add x1, x9, w8, uxtw #3
0x1234034: bl memmove              ; ← NOP THIS
```

### What I've Tried (and Failed)

1. **"krn." string anchor** → Leads to function at `0x11F7EE8`, NOT `0x1233E40`. Wrong function entirely.

2. **"nvram-write-access" entitlement string** → Also leads to a different function.

3. **CASA + 0 callers + retab + ubfiz + memmove filter** → **332 matches**. All IOKit virtual methods follow the same "remove observer from array" pattern with CASA locking.

4. **IONVRAMController metaclass string** → Found at `0xA2FEB`. Has ADRP+ADD refs at `0x125D2C0`, `0x125D310`, `0x125D38C` (metaclass constructors). These set up the metaclass, NOT instance methods.

5. **Chained fixup pointer search for IONVRAMController string** → Failed (different encoding).

### Findings That DO Work

**IONVRAMController vtable found via chained fixup search:**

The verifyPermission function at `0x1233E40` is referenced as a chained fixup pointer in `__DATA_CONST`:

```
__DATA_CONST @ 0x7410B8: raw=0x8011377101233E40 → decoded=0x1233E40 (verifyPermission)
```

**Vtable layout at 0x7410B8:**

| Vtable Idx | File Offset | Content | First Insn |
|------------|-------------|---------|------------|
| [-3] 0x7410A0 | | NULL | |
| [-2] 0x7410A8 | | NULL | |
| [-1] 0x7410B0 | | NULL | |
| [0] 0x7410B8 | 0x1233E40 | **verifyPermission** | pacibsp |
| [1] 0x7410C0 | 0x1233BF0 | sister method | pacibsp |
| [2] 0x7410C8 | 0x10EA4E0 | | ret |
| [3] 0x7410D0 | 0x10EA4D8 | | mov |

**IONVRAMController metaclass constructor pattern:**

```
0x125D2C0: pacibsp
  adrp x0, #0x26fe000
  add x0, x0, #0xa38        ; x0 = metaclass obj @ 0x26FEA38
  adrp x1, #0xa2000
  add x1, x1, #0xfeb        ; x1 = "IONVRAMController" @ 0xA2FEB
  adrp x2, #0x26fe000
  add x2, x2, #0xbf0        ; x2 = superclass metaclass @ 0x26FEBF0
  mov w3, #0x88              ; w3 = instance size = 136
  bl OSMetaClass::OSMetaClass()  ; [5236 callers]
  adrp x16, #0x76d000
  add x16, x16, #0xd60
  add x16, x16, #0x10       ; x16 = metaclass vtable @ 0x76DD70
  movk x17, #0xcda1, lsl #48  ; PAC discriminator
  pacda x16, x17
  str x16, [x0]             ; store PAC'd metaclass vtable
  retab
```

**There's ALSO a combined class registration function at 0x12376D8** that registers multiple classes and references the instance vtable:

```
0x12377F8: adrp x16, #0x741000
  add x16, x16, #0x0a8       ; → 0x7410A8 (vtable[-2])
```

Wait — it actually points to `0x7410A8`, not `0x7410B8`. The vtable pointer with the +0x10 adjustment gives `0x7410A8 + 0x10 = 0x7410B8` which is entry [0]. This is how IOKit vtables work: the isa pointer stores `vtable_base + 0x10` to skip the RTTI header.

### Proposed Dynamic Strategy

**Chain**: "IONVRAMController" string → ADRP+ADD refs → metaclass constructor → extract instance size `0x88` → find the combined class registration function (0x12376D8) that calls OSMetaClass::OSMetaClass() with `mov w3, #0x88` AND uses "IONVRAMController" name → extract the vtable base from the ADRP+ADD+ADD that follows → vtable[0] = verifyPermission → find BL to memmove-like target (>2000 callers) and NOP it.

**Alternative (simpler)**: From the metaclass constructor, extract the PAC discriminator `#0xcda1` and the instance size `#0x88`. Then search __DATA_CONST for chained fixup pointer entries where:
- The preceding 3 entries (at -8, -16, -24) are NULL (vtable header)
- The decoded function pointer has 0 BL callers
- The function contains CASA
- The function ends with RETAB
- The function contains a BL to memmove (>2000 callers)
- **The function contains `movk x17, #0xcda1`** (the IONVRAMController PAC discriminator)

This last filter is the KEY discriminator. Among the 332 candidate functions, only IONVRAMController methods use PAC disc `0xcda1`. Combined with "first entry in vtable" (preceded by 3 nulls), this should be unique.

**Simplest approach**: Search all chained fixup pointers in __DATA_CONST where:
1. Preceded by 3 null entries (vtable start)
2. Decoded target is a function in kern_text
3. Function contains `movk x17, #0xcda1, lsl #48`
4. Function contains BL to target with >2000 callers (memmove)
5. NOP that BL

---

## Patch 2: `patch_thid_should_crash` — FAILING

### Upstream Reference

```python
# patch _thid_should_crash to 0
patch(0x67EB50, 0x0)
```

Writes 4 bytes of zero at file offset `0x67EB50`.

### Analysis

- Offset `0x67EB50` is in a **DATA segment** (not code)
- The current value at this offset is **already 0x00000000** in the test kernel
- This is a sysctl boolean variable (`kern.thid_should_crash`)
- The patch is effectively a **no-op** on this kernel

### What I've Tried

1. **Symbol resolution** → 0 symbols, fails.
2. **"thid_should_crash" string** → Found, but has **no ADRP+ADD code references**. The string is in `__PRELINK_INFO` (XML plist), not in a standalone `__cstring` section.
3. **Sysctl structure search** → Searched for a raw VA pointer to the string in DATA segments. Failed because the string VA is in the plist text, not a standalone pointer.
4. **Pattern search for value=1** → The value is already 0 at the upstream offset, so searching for value=1 finds nothing.

### Proposed Dynamic Strategy

The variable at `0x67EB50` is in the kernel's `__DATA` segment (BSS or initialized data). Since:
- The string is only in `__PRELINK_INFO` (plist), not usable as a code anchor
- The variable has no symbols
- The value is already 0

**Option A: Skip this patch gracefully.** If the value is already 0, the patch has no effect. Log a message and return True (success, nothing to do).

**Option B: Find via sysctl table structure.** The sysctl_oid structure in __DATA contains:
- A pointer to the name string
- A pointer to the data variable
- Various flags

But the name string pointer would be a chained fixup pointer to the string in __PRELINK_INFO, which is hard to search for.

**Option C: Find via `__PRELINK_INFO` plist parsing.** Parse the XML plist to find the `_PrelinkKCID` or sysctl registration info. This is complex and fragile.

**Recommended: Option A** — the variable is already 0 in PCC kernels. Emit a write-zero anyway at the upstream-equivalent location if we can find it, or just return True if we can't find the variable (safe no-op).

Actually, better approach: search `__DATA` segments for a `sysctl_oid` struct. The struct layout includes:
```c
struct sysctl_oid {
    struct sysctl_oid_list *oid_parent;  // +0x00
    SLIST_ENTRY(sysctl_oid) oid_link;   // +0x08
    int oid_number;                      // +0x10
    int oid_kind;                        // +0x14
    void *oid_arg1;                      // +0x18 → points to the variable
    int oid_arg2;                        // +0x20
    const char *oid_name;               // +0x28 → points to "thid_should_crash" string
    ...
};
```

So search all `__DATA` segments for an 8-byte value at offset +0x28 that decodes to the "thid_should_crash" string offset. Then read +0x18 to get the variable pointer.

But the string is in __PRELINK_INFO, which complicates decoding the chained fixup pointer.

---

## Patch 3: `patch_hook_cred_label_update_execve` — FAILING

### Upstream Reference

```python
# Shellcode at 0xAB17D8 (46 instructions, ~184 bytes)
# Two critical BL targets:
#   BL _vfs_context_current at idx 9:  0x940851AC → target = 0xCC5EAC
#   BL _vnode_getattr at idx 17:       0x94085E69 → target = 0xCC91C0
# Ops table patch at 0xA54518: redirect to shellcode
# B _hook_cred_label_update_execve at idx 44: 0x146420B7 → target = 0x239A0B4
```

### Why It Fails

The patch needs two kernel functions that have **no symbols**:
- `_vfs_context_current` at file offset `0xCC5EAC`
- `_vnode_getattr` at file offset `0xCC91C0`

Without these, the shellcode can't be assembled (the BL offsets depend on the target addresses).

### Analysis of _vfs_context_current (0xCC5EAC)

```
Expected: A very short function (2-4 instructions) that:
  - Reads the current thread (mrs xN, TPIDR_EL1 or load from per-CPU data)
  - Loads the VFS context from the thread struct
  - Returns it in x0

Should have extremely high caller count (VFS is used everywhere).
```

Let me verify: check `bl_callers.get(0xCC5EAC, [])` — should have many callers.

### Analysis of _vnode_getattr (0xCC91C0)

```
Expected: A moderate-sized function that:
  - Takes (vnode, vnode_attr, vfs_context) parameters
  - Calls the vnode op (VNOP_GETATTR)
  - Returns error code

Should have moderate caller count (hundreds).
```

### Finding Strategy for _vfs_context_current

1. **From sandbox ops table**: We already have `_find_sandbox_ops_table_via_conf()`. The hook_cred_label_update_execve entry (index 16) in the ops table points to the original sandbox hook function (at `0x239A0B4` per upstream).

2. **From the original hook function**: Disassemble the original hook function. It likely calls `_vfs_context_current` (to get the VFS context for vnode operations). Find the BL target in the hook that has a very high caller count — that's likely `_vfs_context_current`.

3. **Pattern match**: Search kern_text for short functions (size < 0x20) with:
   - `mrs xN, TPIDR_EL1` instruction
   - Very high caller count (>1000)
   - Return type is pointer (loads from struct offset)

### Finding Strategy for _vnode_getattr

1. **From the original hook function**: The hook function likely also calls `_vnode_getattr`. Find BL targets in the hook that have moderate caller count.

2. **String anchor**: Search for `"vnode_getattr"` string (not in plist but in `__cstring`). Find ADRP+ADD refs, trace to function.

3. **Pattern match**: The function signature includes a `vnode_attr` structure initialization with size `0x380`.

### Proposed Implementation

```
1. Find sandbox ops table → read entry at index 16 → get original hook func
2. Disassemble original hook function
3. Find _vfs_context_current: BL target in the hook with highest caller count (>1000)
4. Find _vnode_getattr: BL target that:
   - Has moderate callers (50-1000)
   - The calling site has nearby `mov wN, #0x380` (vnode_attr struct size)
5. With both functions found, build shellcode and patch ops table
```

---

## Patch Status Summary

| Patch | Status | Blocker | Strategy |
|-------|--------|---------|----------|
| nvram_verify_permission | FAILING | Can't distinguish among 332 identical IOKit methods | Use PAC disc `#0xcda1` + vtable header (3 nulls) to find unique IONVRAMController vtable entry |
| thid_should_crash | FAILING | String in __PRELINK_INFO, no code refs, value already 0 | Option A: return True (safe no-op); Option B: sysctl_oid struct search |
| hook_cred_label_update_execve | FAILING | Can't find vfs_context_current and vnode_getattr without symbols | Find via sandbox ops table → original hook → BL targets by caller count |

---

## Previously Fixed Patches (This Session)

### patch_task_for_pid — FIXED

**Problem**: Old code searched for "proc_ro_ref_task" string → wrong function.
**Solution**: Pattern search: 0 BL callers + 2x ldadda + 2x `ldr wN,[xN,#0x490]; str wN,[xN,#0xc]` + movk #0xc8a2 + non-panic BL >500 callers. NOP the second `ldr wN,[xN,#0x490]`.
**Upstream**: `patch(0xFC383C, 0xd503201f)` — NOP in function at `0xFC3718`.

### patch_load_dylinker — FIXED

**Problem**: Old code searched for "/usr/lib/dyld" → wrong function (0 BL callers, no string ref).
**Solution**: Search for functions with 3+ `TST xN, #-0x40000000000000; B.EQ; MOVK xN, #0xc8a2` triplets and 0 BL callers. Replace LAST TST with unconditional B to B.EQ target.
**Upstream**: `patch(0x1052A28, B #0x44)` — in function at `0x105239C`.

### patch_syscallmask_apply_to_proc — FIXED

**Problem**: `bl_callers` key bug: code used `target + self.base_va` but bl_callers is keyed by file offset.
**Fix**: Changed to `self.bl_callers.get(target, [])` at line ~1661.
**Status**: Now PASSING (40 patches emitted for shellcode + redirect).

---

## Environment Notes

### Running on macOS (current)

```bash
cd /Users/qaq/Documents/GitHub/vphone-cli
source .venv/bin/activate
python3 -c "
import sys; sys.path.insert(0, 'scripts')
from fw_patch import load_firmware
from patchers.kernel_jb import KernelJBPatcher
_, data, _, _ = load_firmware('vm/iPhone17,3_26.1_23B85_Restore/kernelcache.release.vphone600')
p = KernelJBPatcher(data)
patches = p.find_all()
print(f'Total patches: {len(patches)}')
"
```

### Running on Linux (cloud)

Requirements:
- Python 3.10+
- `pip install capstone keystone-engine pyimg4`
- Note: `keystone-engine` may need `cmake` and C++ compiler on Linux
- Copy the kernelcache file and upstream reference
- The `setup_venv.sh` script has macOS-specific keystone dylib handling — on Linux, pip install should work directly

Files needed:
- `scripts/patchers/kernel.py` (base class)
- `scripts/patchers/kernel_jb.py` (JB patcher)
- `scripts/patchers/__init__.py`
- `scripts/fw_patch.py` (for `load_firmware()`)
- `vm/iPhone17,3_26.1_23B85_Restore/kernelcache.release.vphone600` (test kernel)
- `/Users/qaq/Documents/GitHub/super-tart-vphone/CFW/patch_fw.py` (upstream reference)

### Quick Test Script

```python
#!/usr/bin/env python3
"""Quick test for failing patches."""
import sys
sys.path.insert(0, 'scripts')
from fw_patch import load_firmware
from patchers.kernel_jb import KernelJBPatcher

_, data, _, _ = load_firmware('vm/iPhone17,3_26.1_23B85_Restore/kernelcache.release.vphone600')
p = KernelJBPatcher(data, verbose=True)

failing = ['patch_nvram_verify_permission', 'patch_thid_should_crash',
           'patch_hook_cred_label_update_execve']
for name in failing:
    p.patches = []
    result = getattr(p, name)()
    status = "PASS" if result else "FAIL"
    print(f'\n>>> {name}: {status} ({len(p.patches)} patches)')
```

---

## Upstream Offsets Reference (iPhone17,3 26.1 23B85)

| Symbol / Patch | File Offset | Notes |
|----------------|-------------|-------|
| kern_text start | 0xA74000 | |
| kern_text end | 0x24B0000 | |
| base_va | 0xFFFFFE0007004000 | |
| _thid_should_crash var | 0x67EB50 | DATA, value=0 |
| _task_for_pid func | 0xFC3718 | patch at 0xFC383C |
| _load_dylinker patch | 0x1052A28 | TST → B |
| verifyPermission func | 0x1233E40 | patch BL at 0x1234034 |
| verifyPermission vtable | 0x7410B8 | __DATA_CONST |
| IONVRAMController metaclass | 0x26FEA38 | |
| IONVRAMController metaclass ctor | 0x125D2C0 | refs "IONVRAMController" string |
| IONVRAMController PAC disc | 0xcda1 | movk x17, #0xcda1 |
| IONVRAMController instance size | 0x88 | mov w3, #0x88 |
| _vfs_context_current | 0xCC5EAC | (from upstream BL encoding) |
| _vnode_getattr | 0xCC91C0 | (from upstream BL encoding) |
| shellcode cave (upstream) | 0xAB1740 | syscallmask |
| shellcode cave 2 (upstream) | 0xAB17D8 | hook_cred_label |
| sandbox ops table (hook entry) | 0xA54518 | index 16 |
| _hook_cred_label_update_execve | 0x239A0B4 | original hook func |
| memmove | 0x12CB0D0 | 3114 callers |
| OSMetaClass::OSMetaClass() | 0x10EA790 | 5236 callers |
| _panic | varies | 8000+ callers typically |
