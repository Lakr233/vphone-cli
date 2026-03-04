# TXM Variant Analysis: release vs research

Analysis of TXM (Trusted Execution Monitor) variants from iPhone17,3 26.3 (23D127)
and PCC-CloudOS 26.3 (23D128) IPSWs.

## Source Files

| Source  | Variant  | IM4P Size | SHA256                |
| ------- | -------- | --------- | --------------------- |
| cloudos | release  | 161025    | `3453eb476cfb53d8...` |
| cloudos | research | 161028    | `93ad9e382d8c6353...` |
| iphone  | release  | 161025    | `3453eb476cfb53d8...` |
| iphone  | research | 161028    | `93ad9e382d8c6353...` |

**Key finding:** Both IPSWs contain identical TXM files (same SHA256).
The TXM binary is shared across iPhone and cloudOS IPSWs.

## Decompressed Binary Overview

| Property          | RELEASE               | RESEARCH              |
| ----------------- | --------------------- | --------------------- |
| Compressed size   | 160726 bytes          | 160729 bytes          |
| Decompressed size | 458784 bytes          | 458784 bytes          |
| Compression       | BVX2 (LZFSE)          | BVX2 (LZFSE)          |
| Format            | Mach-O 64-bit ARM64   | Mach-O 64-bit ARM64   |
| SHA256            | `bfc493e3c7b7dc00...` | `62f40b9cd32a2a03...` |
| File type         | 2 (MH_EXECUTE)        | 2 (MH_EXECUTE)        |
| Load commands     | 11                    | 11                    |
| Flags             | `0x00200001`          | `0x00200001`          |

## Mach-O Segments

Both variants have identical segment layout:

| Segment            | VM Address           | VM Size   | File Offset | File Size |
| ------------------ | -------------------- | --------- | ----------- | --------- |
| `__TEXT`           | `0xfffffff017004000` | `0x10000` | `0x0`       | `0x10000` |
| `__DATA_CONST`     | `0xfffffff017014000` | `0xc000`  | `0x10000`   | `0xc000`  |
| `__TEXT_EXEC`      | `0xfffffff017020000` | `0x44000` | `0x1c000`   | `0x44000` |
| `__TEXT_BOOT_EXEC` | `0xfffffff017064000` | `0xc000`  | `0x60000`   | `0xc000`  |
| `__DATA`           | `0xfffffff017070000` | `0x4000`  | `0x6c000`   | `0x4000`  |
| `__LINKEDIT`       | `0xfffffff017074000` | `0x4000`  | `0x70000`   | `0x20`    |

Segment layout identical: **True**

## Diff Summary

- Total differing bytes: **3358** / 458784 (0.73%)
- Diff regions (16-byte merge gap): **87**

### Diffs by Segment

| Segment       | Regions | Bytes Changed | % of Segment |
| ------------- | ------- | ------------- | ------------ |
| `__TEXT`      | 3       | 3304          | 5.04%        |
| `__TEXT_EXEC` | 84      | 409           | 0.15%        |

## Diff Classification

### 1. Build Identifier String (Primary Difference)

The largest diff region (`0x17c5` - `0x2496`, 3282 bytes) is in the `__TEXT` segment
string/const data area. The key difference is the build variant identifier:

| Offset   | RELEASE                                          | RESEARCH                                          |
| -------- | ------------------------------------------------ | ------------------------------------------------- |
| `0x17c5` | `lease.TrustedExecutionMonitor_Guarded-182.40.3` | `search.TrustedExecutionMonitor_Guarded-182.40.3` |
| `0xcb7f` | `lease`                                          | `search`                                          |

Full build string:

- **RELEASE:** `release.TrustedExecutionMonitor_Guarded-182.40.3`
- **RESEARCH:** `research.TrustedExecutionMonitor_Guarded-182.40.3`

Because `"research"` (8 chars) is 1 byte longer than `"release"` (7 chars),
all subsequent strings in `__TEXT` are shifted by +1 byte,
causing a cascade of instruction-level diffs in code that references these strings.

### 2. String Reference Adjustments (Code Diffs)

The remaining diffs are in `__TEXT_EXEC` — all `ADD` instruction immediate adjustments
compensating for the 1-byte string shift:

```
RELEASE:  add  x8, x8, #0x822   ; points to string at original offset
RESEARCH: add  x8, x8, #0x823   ; points to same string, shifted +1
```

- ADD immediate adjustments: **84** regions (all in `__TEXT_EXEC`)
- Other code diffs: **0** regions
- String data regions: **3** regions in `__TEXT` (3304 bytes total)

Sample code diffs (first 10):

| Offset    | RELEASE instruction  | RESEARCH instruction |
| --------- | -------------------- | -------------------- |
| `0x2572c` | `add x8, x8, #0x822` | `add x8, x8, #0x823` |
| `0x25794` | `add x8, x8, #0x861` | `add x8, x8, #0x862` |
| `0x257d8` | `add x0, x0, #0x877` | `add x0, x0, #0x878` |
| `0x25980` | `add x0, x0, #0x8d7` | `add x0, x0, #0x8d8` |
| `0x25ac8` | `add x0, x0, #0x8a1` | `add x0, x0, #0x8a2` |
| `0x25af0` | `add x4, x4, #0x8eb` | `add x4, x4, #0x8ec` |
| `0x25b78` | `add x0, x0, #0x8f9` | `add x0, x0, #0x8fa` |
| `0x25c34` | `add x2, x2, #0x911` | `add x2, x2, #0x912` |
| `0x25c58` | `add x2, x2, #0x919` | `add x2, x2, #0x91a` |
| `0x25c98` | `add x0, x0, #0x927` | `add x0, x0, #0x928` |

### 3. Functional Differences

**None.** All code diffs are string pointer adjustments caused by the 1-byte
shift from `"release"` to `"research"`. The two variants are **functionally
identical** — same logic, same security policies, same code paths.

## Security-Relevant Strings

Both variants contain identical security-relevant strings:

| Offset   | String                            |
| -------- | --------------------------------- |
| `0xd31`  | `restricted execution mode`       |
| `0x1919` | `debug-enabled`                   |
| `0x1a4e` | `darwinos-security-environment`   |
| `0x1ad0` | `security-mode-change-enable`     |
| `0x1b4b` | `amfi-only-platform-code`         |
| `0x1bd6` | `research-enabled`                |
| `0x1c4c` | `sec-research-device-erm-enabled` |
| `0x1cca` | `vmm-present`                     |
| `0x1d33` | `sepfw-load-at-boot`              |
| `0x1de8` | `sepfw-never-boot`                |
| `0x1e85` | `osenvironment`                   |
| `0x1ec4` | `device-recovery`                 |
| `0x1f81` | `TrustCache`                      |
| `0x202a` | `iboot-build-variant`             |
| `0x20a9` | `development`                     |
| `0x23da` | `image4 dispatch`                 |

## Implications for Patching

1. **Either variant works** — the code is functionally identical.
2. **`fw_patch.py` uses the research variant** (`txm.iphoneos.research.im4p`)
   because the `iboot-build-variant` device tree property in PCC VMs is set to
   `"research"`, and TXM validates this matches its own embedded variant string.
3. **String-based patch anchors** that reference the build variant string
   (`"release"` / `"research"`) will match at different offsets — patchers should
   use variant-agnostic anchors (e.g., `mov w19, #0x2446` as in `txm.py`).
4. **The 3-byte IM4P size difference** (161025 vs 161028 bytes) comes from the
   extra byte in `"research"` plus LZFSE compression variance.
5. **Both IPSWs ship the same TXM** — no need to prefer one source over the other.

## Conclusion

The TXM `release` and `research` variants are **cosmetically different but
functionally identical**. The only real difference is the embedded build variant
string (`"release"` vs `"research"`), which causes a 1-byte cascade in string
offsets and corresponding `ADD` immediate adjustments in code.
Both IPSWs (iPhone and cloudOS) ship the same pair of TXM binaries.
