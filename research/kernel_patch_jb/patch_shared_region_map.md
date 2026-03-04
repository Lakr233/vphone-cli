# B17 `patch_shared_region_map`

## How the patch works
- Source: `scripts/patchers/kernel_jb_patch_shared_region.py`.
- Locator strategy:
  1. Try symbol `_shared_region_map_and_slide_setup`.
  2. Fallback string anchor: `/private/preboot/Cryptexes`.
  3. In function body, find `cmp <reg>, <reg>` followed by `b.ne` style guard.
- Patch action:
  - Rewrite compare to `cmp x0, x0`.

## Expected outcome
- Force compare result toward equality path, weakening rejection branch behavior.

## Target
- Shared region setup guard in `_shared_region_map_and_slide_setup` path.

## IDA MCP evidence
- Anchor string: `0xfffffe000708c481` (`/private/preboot/Cryptexes`)
- xref: `0xfffffe00080769dc`
- containing function start: `0xfffffe0008076260`

## Risk
- Shared-region mapping checks influence process memory layout/security assumptions.
