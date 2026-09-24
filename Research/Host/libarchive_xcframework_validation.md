# libarchive.xcframework — S0 / S2 validation

> Measured 2026-09-23 on Mac16,5 / macOS 26 (26A428), 16 cores.
> Artifact: `Lakr233/libarchive.xcframework` release `upstream.27cbc7827172.2`
> (package release `0.1.1`), slice `macos-arm64_x86_64`.
>
> These two questions gate the `vphone-archive` work: it is the program that is
> meant to replace `gtar`, `bsdtar`, `unzip` and `zstd` in one go, and both
> answers below decide whether that is possible at all.

---

## S0 — is libzstd statically compiled in? **YES**

This is the blocking prerequisite. It matters because a libarchive built
*without* libzstd does not report "unsupported" — it silently routes `.zst`
through `__archive_write_program` and shells out to a `zstd(1)` on `PATH`.
That degradation is invisible to `otool -L`, and only fails on a machine that
does not have Homebrew — which is precisely the machine we care about.

### Symbol evidence

`archive_write_add_filter_zstd.c.o` and `archive_read_support_filter_zstd.c.o`
reference **only** the `ZSTD_*` API and **zero** `__archive_write_program_*`
symbols. The in-library compressor (`_archive_compressor_zstd_open` /
`_write` / `_close` / `_flush`) is present, and libzstd's own implementation
(`_ZSTD_compressStream2`, `_ZSTD_decompressStream`, …) is defined in the
archive rather than undefined. 450 defined `ZSTD_*` symbols in total.

### Runtime evidence (the one that counts)

A probe linking the static archive, run with no `zstd(1)` reachable:

```
$ env -i PATH=/usr/bin:/bin ./s0_zstd_probe out.tzst
  details   : libarchive 3.8.9 ... liblzma/5.8.3 ... libzstd/1.5.7 ...
  entry     : probe.txt
  filter    : zstd
  format    : GNU tar format
  round trip: 180 bytes, byte-identical
  OK
```

The same environment, the same file, the system tar:

```
$ env -i PATH=/usr/bin:/bin /usr/bin/tar -tf out.tzst
tar: Error opening archive: Can't initialize filter; unable to run program "zstd -d -qq"
```

That side-by-side is the whole argument for `vphone-archive` in one screen:
the system's libarchive is 3.7.4 with **no** `libzstd` in its version details
and has to spawn an external program; ours carries `libzstd/1.5.7` and does
not. `R15` is closed, and P0.5 does **not** have to start by adding a static
libzstd to the xcframework.

---

## S2 — does the bundled liblzma have the multithreaded encoder? **YES**

`vm export --max` is xz level 9 with `threads=0`. If the MT encoder were
missing, `threads=0` would silently fall back to one core — correct output,
minutes slower on a large bundle, and nothing in the API reports it.

- `lzma_version_string()` → `5.8.3`, `lzma_cputhreads()` → `16`
- `lzma_stream_encoder_mt()` returns `LZMA_OK`, so the encoder is linked in,
  not merely declared in the header
- `archive_write_add_filter_xz.c.o` references `_lzma_stream_encoder_mt` and
  `_lzma_cputhreads`, so libarchive's own build detected it too
  (`HAVE_LZMA_STREAM_ENCODER_MT`) and the `threads` option is not a no-op

### ⚠️ The measurement trap — read this before re-running the probe

The first run said **no MT benefit**, and that was wrong.

| payload | threads=1 | threads=0 | speedup |
| ------: | --------: | --------: | ------: |
| 192 MiB |    18.90s |    18.31s |   1.03x |
|   1 GiB |    91.26s |    18.87s |   4.84x |

xz parallelises across **blocks**, and the automatic block size at preset 9 is
roughly 3x the 64 MiB dictionary — about 192 MiB. A 192 MiB payload is one
single block, so there is nothing to split and no amount of working MT support
can show a speedup. The library was fine; the probe was too small.

Two things follow:

1. Any future re-validation must use a payload **well above ~192 MiB**, or it
   will reproduce the same false negative.
2. `vm export --max` on a bundle smaller than one block gets no MT benefit.
   That is arithmetic, not a regression — do not go looking for a bug.

---

## Fallout for the admission rule (D2)

The probe binary's full dynamic dependency set, linking the static archive:

```
/usr/lib/libz.1.dylib          /usr/lib/libbz2.1.0.dylib
/usr/lib/libiconv.2.dylib      /usr/lib/libxml2.2.dylib
/System/Library/Frameworks/{CoreFoundation,Security}.framework
/usr/lib/libSystem.B.dylib
```

Every entry is under `/usr/lib` or `/System/Library`, so a `vphone-archive`
built this way passes the admission rule as-is.

Note that **`-llzma` is not needed**: the vendored liblzma is self-sufficient,
and linking without it produces a binary with no dynamic liblzma reference at
all. This is one fewer dynamic dependency than the migration plan assumed —
the plan's §2.1.1 table expected xz to link the system `liblzma.5`.
