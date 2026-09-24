# Kernel Info Queries

Use these commands from repo root (`vphone-cli`).

## Database Introspection

```bash
sqlite3 Research/KernelSymbols/kernel_symbols.db ".schema kernel_symbols"
sqlite3 Research/KernelSymbols/kernel_symbols.db "select count(*) from kernel_symbols;"
sqlite3 Research/KernelSymbols/kernel_symbols.db "select kernel_name, matched, missed, percent, total from kernel_symbols order by kernel_name;"
sqlite3 Research/KernelSymbols/kernel_symbols.db "select kernel_name, json_path from kernel_symbols order by kernel_name;"
```

## Resolve JSON Path By Kernel Name

```bash
sqlite3 Research/KernelSymbols/kernel_symbols.db \
  "select json_path from kernel_symbols where kernel_name='kernelcache.release.vphone600';"
```

```bash
sqlite3 Research/KernelSymbols/kernel_symbols.db \
  "select json_path from kernel_symbols where kernel_name='kernelcache.research.vphone600';"
```

## Fast Symbol Search

```bash
rg -n 'panic' Research/KernelSymbols/json/kernelcache.release.vphone600.bin.symbols.json
rg -n 'mach_trap' Research/KernelSymbols/json/kernelcache.research.vphone600.bin.symbols.json
rg -n '0xfffffe00' Research/KernelSymbols/json/kernelcache.release.vphone600.bin.symbols.json
```

## Use XNU Source Reference

```bash
rg -n 'function_or_symbol_fragment' Research/Reference/xnu/{bsd,osfmk,iokit,security}
```

Prefer direct source matches in `Research/Reference/xnu` for behavioral explanations.
