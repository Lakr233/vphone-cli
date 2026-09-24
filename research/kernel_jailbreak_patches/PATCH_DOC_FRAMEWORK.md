# JB Kernel Patch Document Framework

Use this structure for every `research/kernel_jailbreak_patches/patch_*.md` file.

## 1. Patch Metadata

- Patch ID and filename
- Related patcher module/function
- Analysis date
- Analyst note (static only)

## 2. Patch Goal

- Security or behavior gate being changed
- Why this matters for jailbreak bring-up

## 3. Target Function(s) and Binary Location

- Primary function name and address
- Backup candidate names (if symbol mismatch)
- Patchpoint VA and file offset

## 4. Kernel Source File Location

- Expected source path (for example `osfmk/vm/vm_fault.c`)
- If private/non-XNU component, say so explicitly
- Confidence: `high` / `medium` / `low`

## 5. Function Call Stack

- Upstream callers (entry -> target)
- Downstream callees around patched logic
- Dispatch-table or indirect-call notes where needed

## 6. Patch Hit Points

- Exact instruction(s) before patch (bytes + asm)
- Exact instruction(s) after patch (bytes + asm)
- Any shellcode/trampoline/cave details

## 7. Current Patch Search Logic

- String anchor(s)
- Instruction pattern(s)
- Structural filters and uniqueness checks
- Failure handling when matcher is ambiguous

## 8. Pseudocode (Before)

- Compact pseudocode of original decision path

## 9. Pseudocode (After)

- Compact pseudocode of modified decision path

## 10. Validation (Static Evidence)

- IDA-MCP evidence used
- Symbol JSON cross-check notes
- Why selected site is correct

## 11. Expected Failure/Panic if Unpatched

- Concrete expected error/deny/panic behavior
- Where failure is triggered in control flow

## 12. Risk / Side Effects

- Security impact
- Behavioral regressions or stability risks

## 13. Symbol Consistency Check

- Match result vs recovered symbols: `match` / `mismatch` / `partial`
- If mismatch/partial: likely-correct naming candidates

## 14. Open Questions and Confidence

- Remaining uncertainty
- Confidence score and rationale

## 15. Evidence Appendix

- Relevant addresses, xrefs, constants, strings
- Optional decompiler snippets summary

## Minimum Acceptance Per Document

- All 15 sections present.
- Byte-level before/after included for each hit point.
- Call stack included (not just one symbol mention).
- Kernel source location included with confidence.
- Unpatched failure/panic expectation explicitly described.
