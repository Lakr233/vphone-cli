# S5 — IOGPU resource hash "8-byte stride on 4-byte array" (static, 23F84 + 24B156)

**Verdict: refuted.** In both builds the element store lightsword flagged (`str xzr`, 23C55 `0x9f518f0`)
targets the 8-byte-per-slot element array, not the 4-byte-per-slot control-word array; every other
access uses the stride it was allocated with; the remove index is `& (cap-1)`, never a range check that
could be bypassed; and the hash-table grow can only produce `oldcap * 2^k >= w1` with `oldcap >= 64`,
so capacity 1 is unreachable.

Static only: no device, no VM. Inputs: 23F84 `kernelcache.release.iphone14`, 24B156 `kernelcache.release.v54`.
Tooling: `/tmp/jbresearch/s5/{g.py,xref.py,seqcmp.py,fldw.py,ctrl64.py,scan.py}` (capstone, adrp-slide
0x200000000 for `__TEXT`/`__DATA_CONST`).

## Function map (re-found by string xrefs + hash constant 0x9e3779b97f4a7c15)

| role | 23C55 (lightsword) | 23F84 | 24B156 |
|---|---|---|---|
| group create (gate cap>63, pow2) | 0x9f60fcc | 0xfffffff0095fc22c | 0xfffffe000a07ddb4 |
| IOGPUGroupMemory::create | — | 0xfffffff00960f7cc | 0xfffffe000a0923a4 |
| IOGPUGroupMemory::init (main cap=x2 max 0x80000; pending 0x80/0x100) | — | 0xfffffff00960f860 | 0xfffffe000a092440 |
| table init wrapper (cap<=max) | — | 0xfffffff00960f8e8 | 0xfffffe000a0924d4 |
| **table init** (allocs) | — | 0xfffffff00960f8fc | 0xfffffe000a0924e8 |
| **table grow** | 0x9f7699c | 0xfffffff009610c28 | 0xfffffe000a093ce8 |
| **remove_memory_object** | 0x9f518ac | 0xfffffff0096111a0 | 0xfffffe000a094288 |
| remove_memory_objects (bulk) | — | 0xfffffff0096116d0 | 0xfffffe000a0947f4 |
| move pending -> main | — | 0xfffffff009612274 | 0xfffffe000a09545c |
| addMemoryFromResources (insert) | 0x9f62b38 | 0xfffffff00960fbc4 | 0xfffffe000a0927c4 |
| table destructor | — | 0xfffffff00960fa44 | — |
| free-all walk (bitmap iterate) | — | 0xfffffff00961287c | — |

24B156 entries start with `bti c` one word before the `pacibsp`; branch targets are the `bti`.

Cross-build comparison (`seqcmp.py`, normalized: branch targets relative, adrp pages masked):
init 60 vs 61 instrs — only relocation constants + `bti`; grow 328 vs 336 — identical logic, diffs are
relocations, 1-instruction register shift, and the vtable size getter `+0x88` (23F84) vs `+0x108`
with `xpacd`/`brk` (24B156); remove 280 vs 282 — identical logic, 24B156 uses `ldr x,[x19,x]` instead
of `add+ldr`; group create — identical gates. **Code is the same in both builds.**

## Table layout (table-relative; main table at groupMem+0x80, pending at +0xd8)

| off | field | alloc (init 0x960f8fc / 0xa0924e8) | access stride |
|---|---|---|---|
| +0x00 | elems | kalloc_type(cap<<3) | 8*idx |
| +0x08 | refcounts | kalloc(cap<<2) | 4*idx |
| +0x10 | ctrl words (1 bit/slot probe bitmap) | kalloc(cap<<2) | 4*bucket (32-bit only) |
| +0x18 | occupancy bitmap | kalloc(((cap+63)>>3)&~7) = cap/8 | 8*word |
| +0x28 | capacity | | |
| +0x2c | cap-1 | | |
| +0x30 | MASK = (cap>>6)-1 | | |
| +0x34 | log2(cap) = clz(rbit(cap)) | | |
| +0x38 | count | | |
| +0x40 | max | | |

GroupMemory-relative: main elems +0x80, refcnt +0x88, ctrl +0x90, bitmap +0x98, cap +0xa8, MASK +0xb0,
log2 +0xb4, count +0xb8; pending elems +0xd8, refcnt +0xe0, ctrl +0xe8, bitmap +0xf0, cap +0x100,
MASK +0x108, log2 +0x10c, count +0x110.

## (b) Remove path, instruction by instruction (23F84 0x96111a0; 24B156 0xa094288 identical)

```
0x961126c ldr w8,[x19,#0xa8]; sub w9,w8,#1        ; cap-1
0x9611284 mul x8,x21,0x9e3779b97f4a7c15            ; hash = id * K
0x961128c lsr x10,x8,x10  (x10 = -log2)            ; bucket = hash >> (64-log2)   in [0,cap)
0x9611298 lsl x23,x12,#2 ; cmp x23,w23,sxtw        ; ctrl + 4*bucket  (sxtw = overflow guard, not a range check)
0x96112b0 ldr w12,[x12]                            ; 32-bit ctrl word
0x96112cc add w22,w14,w10 ; and w25,w22,w9         ; idx = bucket+bit; slot = idx & (cap-1)
0x96112d8 ubfiz x14,x25,#3 ; ldr x0,[x15]          ; elems[slot]   8-byte, alloc 8*cap   OK
0x9611300 lsl x9,x25,#2 ; ldr/str w8,[x10]         ; refcnt[slot]  4-byte, alloc 4*cap   OK
0x9611358 lsl x8,x25,#3 ; ldr x21,[x25]            ; elems[slot]   OK
0x9611378 str xzr,[x25]                            ; elems[slot] = NULL  (lightsword 0x9f518f0)  -> 8-byte array
0x9611580 ldr/str w8,[x9]  (x9 = ctrl + 4*bucket)  ; 32-bit clear of probe bit              OK
0x96115b0 and w9,w9,w22,lsr #6                     ; word = (idx>>6) & MASK   in [0, cap/64)
0x96115b4 ldr x12,[x10,w9,uxtw #3]                 ; bitmap[word] 8-byte, alloc 8*ceil(cap/64)  OK
0x96115bc str x11,[x10,w9,uxtw #3]                 ; OK
```

24B156 tail: `0xa0946a0 and w9,w9,w22,lsr#6; 0xa0946a4 ldr x12,[x10,w9,uxtw#3]; 0xa0946ac str x11,[x10,w9,uxtw#3]` — same.

Results for cap in {64,128,256,...,0x80000} (power of two, the only values create allows): elems max
offset 8*(cap-1) < 8*cap; refcnt 4*(cap-1) < 4*cap; ctrl 4*(cap-1) < 4*cap; bitmap 8*(cap/64-1) < cap/8.
**Bytes past allocation on every store: 0, for every capacity.** A mismatch would need an 8-byte store
through the +0x10 pointer; `ctrl64.py` finds **0** 64-bit accesses through the ctrl pointer in any
IOGPUGroupMemory function, in either build.

Header fields cap/cap-1/MASK/log2 are written only by init and the grow swap (`fldw.py`: the only direct
32-bit stores to +0xa8..+0xb4 / +0x100..+0x10c inside 0x960f530..0x9612900 / 0xa092000..0xa095c00 are
to count +0xb8/+0x110). Remove decrements refcount and count only — not the mask (lightsword's
"mask decremented" is the `subs w8,w8,#1` on refcnt at 0x961131c and count at 0x96115c8).

## (c) Callers of the grow (table-relative, same function for both tables)

23F84 `0x9610c28`:

| # | site | function | table | w1 |
|---|---|---|---|---|
| 1 | 0x960fcb0 | addMemoryFromResources 0x960fbc4 | main | `(n + n>>2)`, n = user count + main.count |
| 2 | 0x9610070 | addMemoryFromResources (probe dist > 127) | main | 0 |
| 3 | 0x96105f8 | addMemoryFromResources (probe dist > 127) | pending | 0 |
| 4 | 0x9611bd4 | remove_memory_objects 0x96116d0 (re-insert, probe > 127) | main | 0 |
| 5 | 0x96126cc | move pending->main 0x9612274 (probe > 127) | main | 0 |

24B156 `0xa093ce8`: 0xa0928b0 (site 1, main, w1 = n*5/4), 0xa092e50 (main, 0), 0xa09307c (pending, 0),
0xa09372c (pending, 0), 0xa094d50 (remove_memory_objects, main, 0), 0xa095918 (move pending, main, 0).

Grow body (both builds):
```
w8 = cap; w9 = w8<<1; if (w1 != 0) w9 = w1; x21 = w8
do { w8 = x21<<1; if (x21 >= w9) break; x21 = w8 } while(1)   ; newcap = cap * 2^k >= (w1 ? w1 : 2*cap)
new = alloc(table); init(new, newcap, max=[+0x40], flag=[+0x51]&1)   ; fails if newcap > max
rehash all elements; on rehash failure: free new, x21 <<= 1, retry
swap old <-> new fields; free old; return init status
```

Reachability from the user client: cmd 3 (new group) -> 0x95fc22c -> create -> init (cap = resource type).
cmd 130 (add resources) -> group_add_resources 0x95f15dc -> resource-set add 0x95fe7b8/0x95ff0e4 ->
addMemoryFromResources 0x960fbc4 (sites 1-3). Resource remove -> 0x95fe55c -> thunk 0x96115f4 ->
remove_memory_object (no grow) and -> remove_memory_objects 0x96116d0 (site 4) / move pending (site 5).
Counts: site 1 `n = count + main.count`; sites 2-5 do not use count.

## (d) Can grow run with count == 1 or any count giving capacity 1?

No.
1. Site 1 is entered only when `main.capacity < n*5/4` (`0x960fca4 cmp w8,w1; b.hs skip`); capacity is
   >= 64 at creation and never decreases, so grow needs `n >= 52`. count == 1 never reaches grow.
2. Even when grow runs, the loop starts from `x21 = oldcap >= 64` and only doubles; w1 is a lower bound,
   not the capacity. newcap in [128, ...]. Capacity 1 (log2 = 0, bucket = full 64-bit hash) is unreachable
   from any of the 5 (23F84) / 6 (24B156) callers. Lightsword's "capacity = w1 (explicit)" does not match
   the code in these two builds.
3. Pending table: cap 0x80, max 0x100; a second doubling (0x100 -> 0x200) fails `cap <= max` in the init
   wrapper, grow returns 0, the insert fails cleanly.

## Notes on the lightsword 23C55 reading

No 23C55 kernelcache is available locally, so 23C55 itself was not re-disassembled. The two claims that
would make the bug real — (i) 8-byte store through the `kalloc(cap*4)` array, (ii) grow taking capacity
directly from w1 — are both false in 23F84 and 24B156 at the mapped addresses; most likely they were
misreads of 23C55 as well (the `str xzr` sits 0xA0 bytes after the `+0x10` load, and the grow loop
header `csel w9,w9,w1,eq` precedes the `while (x21 < w9) x21 <<= 1` loop that restores the floor).

## Evidence commands

```
cd /tmp/jbresearch/s5; P=/tmp/jbresearch/venv/bin/python
$P g.py 13 dis 0xfffffff0096111a0 280          # remove, 23F84
$P g.py 17 dis 0xfffffe000a094288 282          # remove, 24B156
$P g.py 13 dis 0xfffffff00960f8fc 60           # init
$P g.py 13 dis 0xfffffff009610c28 328          # grow
$P g.py 13 callers 0xfffffff009610c28 ; $P g.py 17 callers 0xfffffe000a093ce8
$P seqcmp.py 0xfffffff0096111a0 0xfffffe000a094288
$P seqcmp.py 0xfffffff009610c28 0xfffffe000a093cec
$P ctrl64.py 13 ; $P ctrl64.py 17              # 64-bit accesses via ctrl pointer: 0
$P fldw.py 13 0xfffffff00960f530 0xfffffff009612900 0xa8 0xac 0xb0 0xb4 0xb8 0x100 0x104 0x108 0x10c 0x110
```

Dumped listings: `rmo13.txt` (remove 23F84), `grow13.txt`, `addmem13.txt`, `addmem17.txt`,
`rmomulti13.txt`, `movpend13.txt`, `movpend17.txt`, `f95e9520.txt`, `audit13.txt`.
