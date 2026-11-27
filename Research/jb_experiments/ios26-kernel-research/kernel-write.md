# Kernel Write Primitive — RB-Tree Rotation

**Date:** 2026-11-13 (binary-verified)  
**Status:** Disassembled and confirmed. No PAC on tree pointers.

## How It Works

XNU's red-black tree implementation (from BSD `tree.h`) performs pointer writes during
tree rotation (rebalancing). If we control a tree node's fields via UAF reclamation,
those writes go to attacker-controlled addresses.

## The ip_msource RB-Tree

```c
struct ip_msource {
    RB_ENTRY(ip_msource) ims_link;  // +0x00: left(8), right(8), parent(8)
    in_addr_t ims_haddr;            // +0x18: sort key
    struct ims_st ims_st[2];        // +0x1C: state (8 bytes)
    uint8_t ims_stp;                // +0x24: pending
};
// ~40 bytes → kalloc.48
```

Tree is `imf->imf_sources`. RB_ENTRY at offset 0:
- `rbe_left` at +0x00
- `rbe_right` at +0x08
- `rbe_parent` at +0x10 (LSB = RED/BLACK color bit)

## Binary Verification

Disassembled `RB_REMOVE` for `ip_msource_tree` at `0xfffffff00aa314f0`:

- **All tree pointer accesses are plain LDR/STR** — no PAC instructions
- Only PAC in the function is `RETAB` on return (standard function epilogue)
- Tree manipulation is PAC-free

## Write Gadgets (from RB_ROTATE_LEFT)

```c
RB_ROTATE_LEFT(elm, tmp):
    // WRITE 1: elm->rbe_right = tmp->rbe_left
    // WRITE 2: (tmp->rbe_left)->rbe_parent = elm
    // WRITE 3: tmp->rbe_parent = elm->rbe_parent
    // WRITE 4: (elm->rbe_parent)->rbe_{left|right} = tmp    ← MAIN GADGET
    // WRITE 5: tmp->rbe_left = elm
    // WRITE 6: elm->rbe_parent = tmp
```

**Write 4** is the most useful:
```
*(old->rbe_parent + {0 or 8}) = succ
```

- **WHERE:** `old->rbe_parent` — we control this by corrupting the reclaimed node
- **WHAT:** `succ` — a kernel heap pointer (known via read primitive)
- **Offset:** +0 or +8 depending on whether `old` was a left or right child

## Combining with ICMP6_FILTER

The RB rotation gives us a **pointer write** (write a kernel address to a controlled
location). This is enough to redirect `in6p_icmp6filt`:

1. Use RB rotation to write a target object's address into `in6p_icmp6filt`
2. Now `setsockopt(ICMP6_FILTER)` writes 32 bytes to that target
3. Craft the 32-byte payload to modify the target while preserving PAC fields

This two-stage approach gives us:
- **Stage A (RB rotation):** Write a pointer → redirect ICMP6_FILTER
- **Stage B (ICMP6_FILTER):** Write 32 bytes of controlled data to the redirected target

## Zero-Write Primitive (Bonus)

RB_REMOVE of a leaf node + TOCTOU race can write zeros (from Z_ZERO zone clearing)
to a controlled address. Less useful than the rotation write but available as a fallback.

## RB-Tree Structure Details

Color bit is stored in LSB of `rbe_parent`:
```c
GETPARENT(elm) = (rbe_parent & ~1)    // strip color
GETCOLOR(elm)  = (rbe_parent & 1)     // 0=BLACK, 1=RED
SETPARENT(elm, p) { rbe_parent = p | GETCOLOR(elm); }
```

This means `rbe_parent` is always an aligned pointer with the LSB sometimes set.
When we forge a `rbe_parent` value, we need to account for the color bit.
