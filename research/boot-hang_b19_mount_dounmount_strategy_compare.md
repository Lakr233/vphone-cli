# Boot Hang Focus: B19 + (B11/B12) Strategy Comparison

Date: 2026-03-05
Target binary family: `kernelcache.research.vphone600` (iOS 26.1 / 23B85)

## Scope

This note compares two patching styles for boot-hang triage:

1. B19 (`_IOSecureBSDRoot`) patch style mismatch:
   - upstream known-to-work fixed site
   - current dynamic patcher site
2. B11/B12 (`___mac_mount` / `_dounmount`) patch style mismatch:
   - upstream fixed-site patches
   - current dynamic strict-shape patches

The goal is to make A/B testing reproducible with concrete trigger points, pseudocode, and expected runtime effects.

---

## 1) B19 `_IOSecureBSDRoot` mismatch

### 1.1 Trigger points (clean kernel)

- `0x0128B598` (`VA 0xFFFFFE000828F598`) in `sub_FFFFFE000828F42C`
  - before: `b.ne #0x128b5bc`
  - upstream patch: `b #0x128b5bc` (`0x14000009`)
- `0x01362090` (`VA 0xFFFFFE0008366090`) in `sub_FFFFFE0008366008`
  - before: `cbz w0, #0x1362234`
  - current dynamic patch: `b #0x1362234` (`0x14000069`)

Current patched checkpoint confirms:

- `0x01362090` is patched (`b`)
- `0x0128B598` remains unpatched (`b.ne`)

### 1.2 Function logic and pseudocode

#### A) Upstream site function (`sub_FFFFFE000828F42C`)

High-level logic:

1. query `"SecureRootName"` from `IOPlatformExpert`
2. run provider call
3. release objects
4. if return code equals `0xE00002C1`, branch to fallback path (`sub_FFFFFE0007C6AA58`)

Pseudocode:

```c
ret = IOPlatformExpert->call("SecureRootName", ...);
release(...);
if (ret == 0xE00002C1) {
    return fallback_path();
}
return ret;
```

Patch effect at `0x128B598` (`b.ne -> b`):

- always take fallback path, regardless whether `ret == 0xE00002C1`.

#### B) Dynamic site function (`sub_FFFFFE0008366008`)

Key branch:

- `0x136608C`: callback for `"SecureRoot"`
- `0x1366090`: `cbz w0, #0x1362234` (branch into `"SecureRootName"` block)
- `0x1366234` onward: `"SecureRootName"` handling block

Pseudocode:

```c
if (matches("SecureRoot")) {
    ok = callback("SecureRoot");
    if (ok == 0) goto SecureRootNameBlock;  // cbz w0
    // SecureRoot success/failure handling path
}

SecureRootNameBlock:
if (matches("SecureRootName")) {
    // name-based validation + state sync
}
```

Patch effect at `0x1362090` (`cbz -> b`):

- always jump into `SecureRootNameBlock`, regardless `ok`.

### 1.3 A/B variants to test

1. `B19-A` (upstream helper only):
   - patch only `0x128B598`
   - keep `0x1362090` original
2. `B19-B` (dynamic main only):
   - patch only `0x1362090`
   - keep `0x128B598` original
3. `B19-C` (both):
   - patch both sites

### 1.4 Expected observables

- Boot logs around:
  - `apfs_find_named_root_snapshot_xid`
  - `Need authenticator (81)`
  - transition into init / panic frame
- Panic signatures:
  - null-deref style FAR near low address (for current failure class)
  - stack path involving mount/security callback chain

---

## 2) B11/B12 (`___mac_mount` / `_dounmount`) mismatch

### 2.1 Trigger points (clean kernel)

#### Upstream fixed-offset style

- `0x00CA5D54`: `tbnz w28, #5, #0xca5f18` -> `nop`
- `0x00CA5D88`: `ldrb w8, [x8, #1]` -> `mov x8, xzr`
- `0x00CA8134`: `bl #0xc92ad8` -> `nop`

#### Current dynamic style (checkpoint)

- `0x00CA4EAC`: `cbnz w0, #0xca4ec8` -> `nop`  (B11)
- `0x00CA81FC`: `bl #0xc9bdbc` -> `nop`        (B12)

And in checkpoint:

- upstream sites remain original (`0xCA5D54`, `0xCA5D88`, `0xCA8134` unchanged)
- dynamic sites are patched (`0xCA4EAC`, `0xCA81FC` are `nop`)

### 2.2 Function logic and pseudocode

#### A) `___mac_mount`-related branch (dynamic site near `0xCA4EA8`)

Disassembly window:

- `0xCA4EA8`: `bl ...`
- `0xCA4EAC`: `cbnz w0, deny`
- deny target writes non-zero return (`mov w0, #1`)

Pseudocode:

```c
ret = mac_policy_check(...);
if (ret != 0) {   // cbnz w0
    return EPERM_like_error;
}
continue_mount();
```

Dynamic patch (`0xCA4EAC -> nop`) effect:

- ignore `ret != 0` branch and continue mount path.

#### B) Upstream `___mac_mount` two-site style (`0xCA5D54`, `0xCA5D88`)

Disassembly window:

- `0xCA5D54`: `tbnz w28, #5, ...`
- `0xCA5D88`: `ldrb w8, [x8, #1]`

Pseudocode (behavioral interpretation):

```c
if (flag_bit5_set(w28)) goto restricted_path;
w8 = *(u8 *)(x8 + 1);
...
```

Upstream patches:

- remove bit-5 gate branch (`tbnz -> nop`)
- force register state (`ldrb -> mov x8, xzr`)

This is broader state manipulation than dynamic deny-branch patching.

#### C) `_dounmount` path

Upstream site:

- `0xCA8134`: `bl #0xc92ad8` -> `nop`

Dynamic site:

- `0xCA81FC`: `bl #0xc9bdbc` -> `nop`

Pseudocode (generic):

```c
... prepare args ...
ret = mac_or_policy_call_X(...);   // site differs between two strategies
...
ret2 = mac_or_policy_call_Y(...);
```

Difference:

- upstream and dynamic disable different call sites in unmount path;
- not equivalent by construction.

### 2.3 A/B variants to test

1. `MNT-A` (upstream-only style):
   - apply `0xCA5D54`, `0xCA5D88`, `0xCA8134`
   - keep `0xCA4EAC`, `0xCA81FC` original
2. `MNT-B` (dynamic-only style):
   - apply `0xCA4EAC`, `0xCA81FC`
   - keep `0xCA5D54`, `0xCA5D88`, `0xCA8134` original
3. `MNT-C` (both styles):
   - apply all five sites

---

## 3) Combined test matrix (recommended)

For minimal triage noise, run a 3x3 matrix:

- B19 mode: `B19-A`, `B19-B`, `B19-C`
- mount mode: `MNT-A`, `MNT-B`, `MNT-C`

Total 9 combinations, each from the same clean baseline kernel.

Record per run:

1. last APFS logs before failure/success
2. whether `Need authenticator (81)` appears
3. panic presence and panic PC/FAR
4. whether init proceeds past current hang point

---

## 4) Practical note

Do not mix incremental patching across already-patched binaries when comparing these modes.
Always regenerate from clean baseline before each combination, otherwise branch-site interactions can mask true causality.
