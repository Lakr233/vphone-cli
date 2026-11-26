# Native KDK extraction

`KDKExtraction` reconstructs a KDK directly from a decompressed kernel
collection: it recovers references, synthesizes cross-image symbols, writes
standalone Mach-Os with `KDKImageExport`, and recreates bundle plists and KPI
pseudo-extensions. `KernelCacheMixer` uses this native implementation and
in-process gzip decompression. It does not execute an external `ipsw`.

The current contract is stripped collections with address-only synthetic binds.
Passing `addressOnlyBinds: false` fails explicitly. Original-symbol C++ alias/PAC
name inference and general shared-cache dylib export are outside this stage.
Nonempty export tries, code signatures, code-signing DRs and linker optimization
hints are rejected rather than preserved with obsolete LINKEDIT offsets.

## Export an image

The internal API takes a decompressed MH_FILESET and an image parsed from it:

```swift
// collection, image, symbols and references come from the extraction layer.
var writer = try KDKImageExport(
    collection: collection,
    image: image,
    baseAddress: baseAddress,
    symbols: symbols,
    references: references,
    addressOnlyBinds: true
)
let standaloneMachO = try writer.export()
```

Use zero as the KEXT base, and the collection's preferred load address for the
kernel. Before exporting `com.apple.kernel`, replace its LC_UNIXTHREAD in place
with the collection's LC_UNIXTHREAD, matching `extract.go`'s
`fixUnixThreadAddress`. This belongs to the caller, not the generic image writer.

Nonempty references select contiguous segment packing. Without references the
writer preserves cache VM addresses while packing file offsets. Input images
and collections stay immutable; repeated exports from the same writer reset
its scratch state and produce the same bytes.

## Reference and evidence

The port follows the MIT-licensed `File.Export` in go-macho PR #94. Its license
is retained in `FirmwarePatcher/KernelCache/KDK/LICENSE` and packaged as
`Contents/Resources/Licenses/native-kdk-MIT.txt`. The external reference
build uses these pinned mpass99 commits, not the released upstream `ipsw`:

| Repository | Commit |
| --- | --- |
| ipsw | `7d81acd4b97e67c0a25b5ddc514ce2ad02e7d474` |
| go-macho | `a8b76580904cdec5a634a9bbc9e8e976d80ddf06` |
| arm64-cgo | `5cac24a3a47df0c29fe6f4ba956dd25b216e54b2` |
| go-dwarf | `bfc1862b701d882faf1cc421f90b960727991e15` |

On 2026-10-23 the writer reproduced **all 264 reference exports byte for byte**:
144 fileset images from `kernelcache.release.vphone600` and 120 from
`kernelcache.release.vresearch101`, including both kernels. The comparison
feeds the identical references/symbols/base/bind mode into Swift and Go. It does
not use the reference output to construct Swift output. This proves the writer
for these inputs; a separate native recovery test now reconstructs all inputs
from the collections and checks reference sets, symbol arrays and final bytes.
Both collections match all 264 images with zero unresolved imports. Full KDK
tree tests also match 313 donor files and 263 research files: executable bytes
are identical, while plist fields and values are equal (XML formatting is not
part of the contract). No new kmutil link or VM boot was performed.

Corpus source: cached cloudOS 26.4 beta IPSW
`c0ecdb4b310cf5239ab2b248dd3098eec297dc5aa3bbe6ad-b80d96a0b616.ipsw`.
The decompressed input hashes are:

| Kernel | SHA-256 |
| --- | --- |
| vphone600 | `681801fe328b00ff8ec2e94a3d84bf9f9a7a1b954640d0c40f8dd02434270935` |
| vresearch101 | `fe345b332fc50586e21707be69accc63e7bc7a855178481a6436727cc24a4e8b` |

The source bytes, captured inputs, and Go exports are external test data. No
Apple firmware, Go runtime, Python, or Homebrew dependency is added to the
shipped bundle. The Go reference is only a development oracle.

## Run the tests

From the repository root, build through the workspace so shared Kit targets are
resolved, using the owning `FirmwarePatcherTests` scheme:

```zsh
xcodebuild -workspace VPhone.xcworkspace -scheme FirmwarePatcherTests \
  -configuration Debug -destination 'platform=macOS,arch=arm64' \
  -derivedDataPath /tmp/native-kdk-build test
```

`KDKExportFixtureTests` creates an entirely synthetic collection. It checks
contiguous layout, restored auth stubs and calls, authenticated binds/rebases,
indirect-symbol fallback, function-start remapping, repeatability, the
cache-address path, and malformed-command rejection. `KDKImageExportTests`
checks all four pointer layouts, signed bind addends, BRAA and OFF12 encodings,
Capstone decoding, and ADRP at high kernel addresses.

BRAA is checked against Apple clang because Keystone 0.9.2 rejects PAC
mnemonics. Independent assembly produced `braa x16, x17 = 0xD71F0A11`,
`braa x0, x1 = 0xD71F0801`, and `braa x30, sp = 0xD71F0BDF`.

The real-corpus test is opt-in. Set `KDK_CORPUS` to an external corpus root with
this layout (the fixture labels are deliberately stable):

```text
data/264beta/kernelcache.release.vphone600.decompressed
data/264beta/kernelcache.release.vresearch101.decompressed
parity/donor/inputs/<entryID>.json
parity/donor/out/<reference-output-path>
parity/research/inputs/<entryID>.json
parity/research/out/<reference-output-path>
```

With `KDK_CORPUS` set in the shell, run:

```zsh
TEST_RUNNER_KDK_PARITY_ROOT="$KDK_CORPUS" \
xcodebuild -workspace VPhone.xcworkspace -scheme FirmwarePatcherTests \
  -configuration Debug -destination 'platform=macOS,arch=arm64' \
  -derivedDataPath /tmp/native-kdk-build \
  -only-testing:FirmwarePatcherTests/KDKImageExportTests \
  -only-testing:FirmwarePatcherTests/KDKExportFixtureTests \
  -only-testing:FirmwarePatcherTests/KDKRecoveryTests \
  -only-testing:FirmwarePatcherTests/KDKRecoveryFlowTests \
  -only-testing:FirmwarePatcherTests/KDKExtractionTests test
```

Xcode strips the `TEST_RUNNER_` prefix for the test process. To narrow a failure,
set `TEST_RUNNER_KDK_PARITY_ENTRY=com.apple.kernel`; the test then expects two
exports, one per collection. A mismatch reports the first byte offset and saves
`swift-<corpus>-<entryID>` in the corpus root. The default test run skips the
external corpus rather than silently treating absent firmware as success.

The final native integration validation on 2026-10-23 passed **86 tests in 12
suites**, including the mixer's shipped gzip symbol-map path, all native
recovery/export/tree comparisons and the patch-set contract suites. The
writer-stage validation also passed the ARM64 encoder suite. Its full scheme
run reported 134 issues among 696 tests: existing suites require missing `ipsws/ref_extract` DSC/Mach-O fixtures
and `ipsws/patch_refactor_input` payloads in this new worktree. The main
checkout's DSC directory is empty and the patch-refactor inputs are absent too.
That run is recorded as failed, not as a clean full-suite validation.

The complete `VPhone` scheme build passed, including `Bundle admission passed`.
Local acceptance data is retained under `.build/KDKParity` (ignored by Git),
with focused/full-test and bundle logs in its `validation` directory. Set
`KDK_CORPUS="$PWD/.build/KDKParity"` to replay the corpus from this worktree.

## Rebuild the external reference

Place the four pinned repositories in sibling directories named `ipsw`,
`go-macho`, `arm64-cgo`, and `go-dwarf`, outside this checkout. Apply
[`native_kdk_reference_inputs.diff`](native_kdk_reference_inputs.diff) to the
**external ipsw checkout**. It adds `KDK_DUMP_INPUTS`, which serializes each
`Export` call's entry ID, output path, base, address-only flag, extra symbols and
references before writing the reference binary. It changes no export behavior.

From that external ipsw checkout:

```zsh
cp go.mod go.ref.mod
cp go.sum go.ref.sum
go mod edit -modfile=go.ref.mod -replace github.com/blacktop/go-macho=../go-macho
go mod edit -modfile=go.ref.mod -replace github.com/blacktop/arm64-cgo=../arm64-cgo
go mod edit -modfile=go.ref.mod -replace github.com/blacktop/go-dwarf=../go-dwarf
go build -mod=mod -modfile=go.ref.mod -o ../ipsw-ref ./cmd/ipsw
```

Run `ipsw-ref kernel extract --kdk` for each decompressed collection, adding
`--symbols` followed by the symbol-map filename when one is available,
with `KDK_DUMP_INPUTS` pointing to that corpus's `inputs` directory and the output
root pointing to its `out` directory. Retain any explicit symbols input used
when building the reference corpus; the dump records the resulting writer
inputs, so writer parity does not depend on re-running symbol synthesis.

## Layout invariants

1. Build the segment map, resize `__auth_stubs`, and move later segments before
   copying commands. A containing segment wins over another segment's end;
   section positions move with their own segment to resolve adjacent ranges.
2. Keep the source header's `ncmds` and `sizeofcmds`, adjusting only for explicit
   command additions/removals, as the reference does. Place chained fixups after
   the last segment and split info immediately before function starts.
3. Copy source segment bytes through the collection's address map. Write auth
   stubs, relocate references, reconnect external branches, clear the packed
   `_kmod_info` address/size fields, then restore the FIPS HMAC-SHA256 seal.
4. Reconstruct chained fixups with 4 KiB pages and a four-byte next stride.
   Preserve PAC diversity/address-diversity/key; use low43/high8 for plain
   rebases, 16-bit ordinals and signed19 embedded addends for binds. Import order
   follows sections/atoms, including destructor-pair atom boundaries.
5. Rebuild LINKEDIT in reference order, align blobs to eight bytes, renumber
   symbols and indirect symbols, and truncate the obsolete original tail.
   Symbol records are local/defined/undefined; strings are defined/undefined/local.

## Native recovery and integration

`KDKRecovery` decodes collection pointer chains, LC_FUNCTION_STARTS, ADRP and
cross-section branches, unwind image offsets, static-if/copyio deltas and EH
frame references. OFF12 recovery follows register copies, conditional paths,
jump tables and outlined helpers. Leaf callees that clobber a tracked register
end the path; outlined ADRPs can hand their value back to callers. Foreign
noreturn analysis prevents a call to a terminating function from inventing
consumers in the next block. The pinned reference's query order and failed
jump-table-reader behavior are preserved for reproducibility.

`KDKLinkSymbols` applies transitive dependency visibility to kernel KPI names,
keeps duplicate known KEXT names local, reserves vtable/metaclass and alias
names, and supplies every KEXT's `_kmod_info`. Production extraction refuses
unresolved imports. Metadata paths are constrained to the newly created KDK;
partial exports are removed on failure and the final directory is published
only after success. Host artifacts use the repository's 0777 permission rule.

`KernelCacheMixer` revision 4 keys the mix and donor extraction on
`KDKExtraction.revision`, so pre-native cache entries are rebuilt. It records
`extractor.version` instead of the external executable hash. Staging remains
unprivileged; root only links a staged volume through the existing descriptor
based copy. `checkMixable` reports missing staging before a root pipeline starts.

`fw kernelcache --ipsw <path>`, the Swift `stage(ipsw:)` argument and the
`VPHONE_IPSW` constant were accepted but ignored from 2.12.x on. Series 2.20
removes all three, with the Launchpad ipsw field and the
`vphone-launchpad-cli create --ipsw` passthrough, and raises
`minimumBundleComponents` to 2.20.0.

Validation covers the two pinned 26.4 beta collections. Other recipe generations
and a fresh native-extraction -> kmutil -> guest boot remain separate acceptance
gates; old boot evidence is not evidence of this new extraction path.
