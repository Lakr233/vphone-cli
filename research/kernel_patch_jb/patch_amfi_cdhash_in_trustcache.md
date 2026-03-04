# A1 `patch_amfi_cdhash_in_trustcache`

## 1) How the Patch Is Applied
- Source implementation: `scripts/patchers/kernel_jb_patch_amfi_trustcache.py`
- Match strategy: no string anchor; uses an AMFI function semantic sequence match (`mov x19, x2` -> `stp xzr,xzr,[sp,...]` -> `mov x2, sp` -> `bl` -> `mov x20, x0` -> `cbnz w0` -> `cbz x19`).
- Rewrite: replace the first 4 instructions at function entry with a stub:
  1. `mov x0, #1`
  2. `cbz x2, +8`
  3. `str x0, [x2]`
  4. `ret`

## 2) Expected Behavior
- Always report "CDHash is in trustcache" as true (return `1`).
- If the caller passes an out parameter (`x2` is non-null), write the same result back to the out pointer.

## 3) Target
- Target function logic: AMFI trustcache membership check (script label: `AMFIIsCDHashInTrustCache`).
- Security objective: bypass AMFI's key gate that verifies whether a signing hash is trusted.

## 4) IDA MCP Binary Evidence
- IDB: `/Users/qaq/Desktop/kernelcache.research.vphone600.macho`
- imagebase: `0xfffffe0007004000`
- An IDA semantic-sequence scan (same signature as the script) found 1 hit in the AMFI area:
  - Function entry: `0xfffffe0008637880`
- This function is called by multiple AMFI paths (sample xrefs):
  - `0xfffffe0008635de4`
  - `0xfffffe000863e554`
  - `0xfffffe0008641e0c`
  - `0xfffffe00086432dc`

## 5) Risks and Side Effects
- Forces all CDHash trust decisions to allow, which is highly intrusive.
- If callers rely on the failure path for cleanup or auditing, this patch short-circuits that behavior.
