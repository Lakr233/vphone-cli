---
name: kernel-analysis-vphone600
description: Analyze vphone600 kernel artifacts using the local symbol database and XNU source tree. Use when working on kernel reverse engineering, address-to-symbol lookup, release-vs-research kernel comparison, or patch analysis for vphone600 variants in this repository.
---

# Kernel Analysis Vphone600

Use the local `research/kernel_symbols` dataset as the first source of truth for symbol lookup.
Use `research/reference/xnu` as the source-level reference for semantics and structure.

## Required Paths

- `research/kernel_symbols/kernel_symbols.db`
- `research/kernel_symbols/kernel_index.tsv` (plain-text `kernel_name → json_path` index with `json_sha256`)
- `research/kernel_symbols/json/` — the recovered symbol datasets:
  - `kernelcache.release.vphone600.bin.symbols.json`
  - `kernelcache.research.vphone600.bin.symbols.json`
- `research/reference/xnu`

The `json_path` column in both the database and `kernel_index.tsv` records the absolute path from symbolication
time and may not match this checkout; resolve the JSON files under `research/kernel_symbols/json/` instead.

If `research/reference/xnu` is missing, create it with a shallow clone:

```bash
mkdir -p research/reference
git clone --depth 1 https://github.com/apple-oss-distributions/xnu.git research/reference/xnu
```

## Workflow

1. Confirm scope is `vphone600` only.
2. Query `kernel_symbols.db` to select `release` or `research` dataset by name.
3. Load the linked JSON symbol file and perform symbol/address lookups.
4. Cross-reference candidate code paths in `research/reference/xnu`.
5. Report findings with explicit kernel name, symbol path, and address.

## Output Rules

- Always include which kernel was used: `kernelcache.release.vphone600` or `kernelcache.research.vphone600`.
- Always include exact symbol name and address when available.
- Always distinguish fact from inference when mapping symbols to XNU behavior.
- Avoid claiming coverage outside vphone600 unless explicitly requested.

## References

- Read `references/kernel-info-queries.md` for reusable SQL and shell query snippets.
