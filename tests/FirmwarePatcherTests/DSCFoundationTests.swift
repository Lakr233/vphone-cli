// DSCFoundationTests.swift — Cross-checks for the DSC foundation layer.
//
// `codesign -v` does not apply to a dyld shared cache chunk, so the only
// independent reference for any of this is the Python in `scripts/patchers/`.
// Every test here therefore runs the Python on the same bytes and compares,
// rather than asserting against a number this repo wrote down once.
//
// The tests need the real cache. Point `VPHONE_DSC_PRISTINE` at a directory of
// `dyld_shared_cache_arm64e*` chunks, or leave the default
// `ipsws/ref_extract/dsc_pristine` in place.
//
// Without it they FAIL. They used to open with `guard let pristine = … else
// { return }`, and a bare `return` is reported by Swift Testing as a pass — so
// "13 tests passed" was equally compatible with "13 tests did nothing", on any
// machine that had not extracted the 5.3 GB cache. A machine that genuinely
// cannot carry the fixture sets `VPHONE_DSC_FIXTURE_OPTIONAL=1`, which turns
// the failure into a visible *skip*. There is no configuration in which a green
// run means the cache was absent.
//
// Nothing here writes to the pristine directory. The re-signing tests clone it
// — `clonefile`, so instant and free on APFS — and work in the copy.

@testable import FirmwarePatcher
import Foundation
import Testing

// MARK: - Fixture discovery

private enum DSCFixture {
    static let repoRoot = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()

    /// The read-only reference cache.
    static var pristine: URL? {
        let url = ProcessInfo.processInfo.environment["VPHONE_DSC_PRISTINE"]
            .map { URL(fileURLWithPath: $0) }
            ?? repoRoot.appendingPathComponent("ipsws/ref_extract/dsc_pristine")
        let main = url.appendingPathComponent("dyld_shared_cache_arm64e")
        return FileManager.default.fileExists(atPath: main.path) ? url : nil
    }

    /// Opt-out for a machine that cannot carry the fixture. Set it and the
    /// suites report as skipped; leave it unset and a missing cache is a
    /// failure, which is the only reading of "green" this layer can afford.
    static var isOptional: Bool {
        ProcessInfo.processInfo.environment["VPHONE_DSC_FIXTURE_OPTIONAL"] == "1"
    }

    /// The suites run unless the cache is absent *and* the caller opted out.
    static var runs: Bool { pristine != nil || !isOptional }

    static let missing: Comment = """
    the real 24A435 arm64e shared cache is required — put it at \
    ipsws/ref_extract/dsc_pristine, point VPHONE_DSC_PRISTINE at it, or set \
    VPHONE_DSC_FIXTURE_OPTIONAL=1 to skip these tests instead of failing
    """

    static let skipReason: Comment =
        "VPHONE_DSC_FIXTURE_OPTIONAL=1 and no dyld_shared_cache_arm64e fixture present"

    /// Where clones are made. Same filesystem as the pristine copy, so
    /// `cp -c` is a clone rather than 6.7 GB of reads.
    ///
    /// Deliberately a sibling of `ref_extract/`, not a child of it. This used
    /// to sit at `ref_extract/scratch_dscfoundation`, inside the pristine tree
    /// the whole suite compares against: the cleanup works, but any run that
    /// is interrupted leaves multi-GB clones in there, and a reference tree
    /// with scratch in it is no longer a reference. `ipsws/` is the same
    /// filesystem, so the clone is still a clone.
    static var scratchRoot: URL {
        repoRoot.appendingPathComponent("ipsws/scratch_dscfoundation")
    }

    /// The project venv, which is where the reference Python lives.
    static var python: URL? {
        let url = repoRoot.appendingPathComponent(".venv/bin/python3")
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }

    static var ipsw: URL? {
        let url = URL(fileURLWithPath: "/opt/homebrew/bin/ipsw")
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }

    /// Clone the pristine cache into a fresh directory the caller may write to.
    static func cloneCache(named name: String) throws -> URL {
        guard let pristine else { throw CocoaError(.fileNoSuchFile) }
        let destination = scratchRoot.appendingPathComponent(name)
        try? FileManager.default.removeItem(at: destination)
        try FileManager.default.createDirectory(
            at: destination,
            withIntermediateDirectories: true
        )
        let result = try Subprocess.run(
            executable: URL(fileURLWithPath: "/bin/cp"),
            arguments: ["-c", "-R"]
                + (try FileManager.default.contentsOfDirectory(atPath: pristine.path))
                .sorted()
                .map { pristine.appendingPathComponent($0).path }
                + [destination.path]
        )
        guard result.status == 0 else {
            throw CocoaError(.fileWriteUnknown)
        }
        return destination
    }

    /// Discard a clone, and the scratch root with it once the last clone is
    /// gone — the suite used to leave an empty `scratch_dscfoundation/` behind
    /// on every run, so the working tree was not left as found.
    static func discard(_ clones: URL...) {
        for clone in clones {
            try? FileManager.default.removeItem(at: clone)
        }
        let remaining = (try? FileManager.default
            .contentsOfDirectory(atPath: scratchRoot.path)) ?? []
        if remaining.isEmpty {
            try? FileManager.default.removeItem(at: scratchRoot)
        }
    }
}

// MARK: - Subprocess helper

private enum Subprocess {
    struct Result {
        let status: Int32
        let stdout: String
        let stderr: String
    }

    @discardableResult
    static func run(
        executable: URL,
        arguments: [String],
        currentDirectory: URL? = nil
    ) throws -> Result {
        let process = Process()
        process.executableURL = executable
        process.arguments = arguments
        if let currentDirectory { process.currentDirectoryURL = currentDirectory }
        let out = Pipe()
        let err = Pipe()
        process.standardOutput = out
        process.standardError = err
        try process.run()
        // Drain before waiting: a full pipe buffer would deadlock a symbol dump.
        let outData = out.fileHandleForReading.readDataToEndOfFile()
        let errData = err.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return Result(
            status: process.terminationStatus,
            stdout: String(decoding: outData, as: UTF8.self),
            stderr: String(decoding: errData, as: UTF8.self)
        )
    }
}

// MARK: - The reference Python, driven as an oracle

/// A tiny driver around `cfw_dsc_chunks` / `cfw_dsc_codesign`, written to a
/// temp file at test time. It adds no logic of its own — every number it
/// prints comes out of the modules under `scripts/patchers/`, which is the
/// point: the comparison has to be against that code, not a transcription.
private enum PythonOracle {
    static let source = #"""
import hashlib
import json
import os
import sys

sys.path.insert(0, os.path.join(sys.argv[1], "scripts", "patchers"))

from cfw_dsc_chunks import DSCChunks, _enumerate_chunks, _parse_chunk_mappings, resolve_local_symbol
from cfw_dsc_codesign import _read_chunk_cd_blob, reattest_modified_pages

command = sys.argv[2]
chunks_dir = sys.argv[3]

if command == "layout":
    out = {"chunks": [], "mappings": []}
    for path in _enumerate_chunks(chunks_dir):
        out["chunks"].append(os.path.basename(path))
    c = DSCChunks(chunks_dir)
    for addr, end, foff, prot, cp in c.mappings():
        out["mappings"].append({
            "address": addr, "end": end, "file_offset": foff,
            "init_prot": prot, "chunk": os.path.basename(cp),
        })
    print(json.dumps(out))

elif command == "bytes":
    # argv[4] = JSON file of [[vma, length], ...]
    with open(sys.argv[4]) as f:
        requests = json.load(f)
    c = DSCChunks(chunks_dir)
    out = []
    for vma, length in requests:
        cp, foff = c.find_chunk_for_vma(vma)
        out.append({
            "vma": vma,
            "length": length,
            "chunk": os.path.basename(cp),
            "file_offset": foff,
            "bytes": c.bytes_at_vma(vma, length).hex(),
        })
    print(json.dumps(out))

elif command == "coderdirs":
    out = {}
    for path in _enumerate_chunks(chunks_dir):
        out[os.path.basename(path)] = _read_chunk_cd_blob(path)
    print(json.dumps(out))

elif command == "patch_and_reattest":
    # argv[4] = vma, argv[5] = replacement bytes as hex
    vma = int(sys.argv[4], 0)
    data = bytes.fromhex(sys.argv[5])
    c = DSCChunks(chunks_dir)
    before = c.bytes_at_vma(vma, len(data)).hex()
    c.write_at_vma(vma, data)
    diags = reattest_modified_pages(c, [vma], dry_run=False, verbose=False)
    print(json.dumps({"before": before, "diagnostics": diags}))

elif command == "write_at":
    # argv[4] = vma, argv[5] = replacement bytes as hex. Write only, no re-sign.
    vma = int(sys.argv[4], 0)
    data = bytes.fromhex(sys.argv[5])
    c = DSCChunks(chunks_dir)
    c.write_at_vma(vma, data)
    print(json.dumps({"ok": True}))

elif command == "reattest_dry":
    vma = int(sys.argv[4], 0)
    c = DSCChunks(chunks_dir)
    diags = reattest_modified_pages(c, [vma], dry_run=True, verbose=False)
    print(json.dumps({"diagnostics": diags}))

elif command == "local_symbol":
    print(json.dumps({"address": resolve_local_symbol(chunks_dir, sys.argv[4])}))

elif command == "string_vmas":
    c = DSCChunks(chunks_dir)
    print(json.dumps(c.find_string_vmas(sys.argv[4].encode())))

elif command == "image_at":
    # argv[4] = vma; walk back to the image header and read its install name
    vma = int(sys.argv[4], 0)
    c = DSCChunks(chunks_dir)
    header = c.find_macho_header_before(vma)
    print(json.dumps({
        "header": header,
        "install_name": c.read_install_name_at(header) if header else None,
    }))

elif command == "page_digest":
    # argv[4] = chunk basename, argv[5] = page index, argv[6] = page size
    path = os.path.join(chunks_dir, sys.argv[4])
    page_size = int(sys.argv[6])
    with open(path, "rb") as f:
        f.seek(int(sys.argv[5]) * page_size)
        page = f.read(page_size)
    print(json.dumps({"sha256": hashlib.sha256(page).hexdigest()}))

elif command == "slot_state":
    # argv[4] = chunk basename, argv[5] = page index. What the page hashes to
    # now, and what its code slot currently says it hashes to.
    path = os.path.join(chunks_dir, sys.argv[4])
    meta = _read_chunk_cd_blob(path)
    page_index = int(sys.argv[5])
    with open(path, "rb") as f:
        f.seek(page_index * meta["page_size"])
        page = f.read(meta["page_size"])
        f.seek(meta["cd_file_off"] + meta["hash_offset"]
               + page_index * meta["hash_size"])
        stored = f.read(meta["hash_size"])
    print(json.dumps({
        "computed": hashlib.sha256(page).hexdigest(),
        "stored": stored.hex(),
        "page_size": meta["page_size"],
    }))

elif command == "file_bytes":
    # argv[4] = chunk basename, argv[5] = file offset, argv[6] = length
    path = os.path.join(chunks_dir, sys.argv[4])
    with open(path, "rb") as f:
        f.seek(int(sys.argv[5], 0))
        print(json.dumps({"bytes": f.read(int(sys.argv[6])).hex()}))

else:
    raise SystemExit(f"unknown command {command}")
"""#

    static func scriptURL() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("dsc_oracle_\(ProcessInfo.processInfo.processIdentifier).py")
        if !FileManager.default.fileExists(atPath: url.path) {
            try source.write(to: url, atomically: true, encoding: .utf8)
        }
        return url
    }

    @discardableResult
    static func run(
        _ command: String,
        directory: URL,
        extra: [String] = []
    ) throws -> Data {
        guard let python = DSCFixture.python else { throw CocoaError(.fileNoSuchFile) }
        let script = try scriptURL()
        let result = try Subprocess.run(
            executable: python,
            arguments: [
                script.path,
                DSCFixture.repoRoot.path,
                command,
                directory.path,
            ] + extra
        )
        guard result.status == 0 else {
            Issue.record("python oracle \(command) failed: \(result.stderr)")
            throw CocoaError(.fileReadUnknown)
        }
        return Data(result.stdout.utf8)
    }

    /// What one page hashes to now, and what its slot claims, read straight
    /// out of the code directory by the reference implementation.
    struct SlotState: Decodable {
        let computed: String
        let stored: String
        let page_size: Int

        var isAttested: Bool { computed == stored }
    }

    static func slotState(
        directory: URL,
        chunk: String,
        page: Int
    ) throws -> SlotState {
        try JSONDecoder().decode(
            SlotState.self,
            from: run("slot_state", directory: directory, extra: [chunk, String(page)])
        )
    }
}

// MARK: - 3.1 · Flat addressing

@Suite(.serialized, .enabled(if: DSCFixture.runs, DSCFixture.skipReason))
struct DSCFlatAddressingTests {
    private struct PythonLayout: Decodable {
        struct Mapping: Decodable {
            let address: UInt64
            let end: UInt64
            let file_offset: UInt64
            let init_prot: UInt32
            let chunk: String
        }

        let chunks: [String]
        let mappings: [Mapping]
    }

    private struct PythonBytes: Decodable {
        let vma: UInt64
        let length: Int
        let chunk: String
        let file_offset: Int
        let bytes: String
    }

    @Test("Chunk enumeration and mapping table match cfw_dsc_chunks.py")
    func layoutMatchesPython() throws {
        let pristine = try #require(DSCFixture.pristine, DSCFixture.missing)
        try #require(DSCFixture.python != nil, "project venv is required for the cross-check")

        let chunks = try DSCChunkSet(directory: pristine)
        let reference = try JSONDecoder().decode(
            PythonLayout.self,
            from: PythonOracle.run("layout", directory: pristine)
        )

        #expect(chunks.chunkURLs.map(\.lastPathComponent).sorted() == reference.chunks.sorted())
        #expect(chunks.mappings.count == reference.mappings.count)

        for (mine, theirs) in zip(chunks.mappings, reference.mappings) {
            #expect(mine.address == theirs.address)
            #expect(mine.endAddress == theirs.end)
            #expect(mine.fileOffset == theirs.file_offset)
            #expect(mine.initProt == theirs.init_prot)
            #expect(mine.chunkURL.lastPathComponent == theirs.chunk)
        }
        print(
            "[layout] \(chunks.chunkURLs.count) chunks, \(chunks.mappings.count) mappings, "
                + "vm 0x\(String(chunks.addressRange.lowerBound, radix: 16, uppercase: true))"
                + "..0x\(String(chunks.addressRange.upperBound, radix: 16, uppercase: true))"
        )
    }

    /// Reads spread across every mapping, including the first and last bytes of
    /// each one — the spots where an off-by-one in the boundary test would
    /// silently read out of the neighbouring chunk.
    private func probeRequests(for chunks: DSCChunkSet) -> [(UInt64, Int)] {
        var requests: [(UInt64, Int)] = []
        for mapping in chunks.mappings {
            requests.append((mapping.address, 16))
            requests.append((mapping.endAddress - 8, 8))
            requests.append((mapping.endAddress - 1, 1))
            if mapping.size >= 256 {
                let middle = (mapping.address + mapping.size / 2) & ~7
                requests.append((middle, 64))
            }
        }
        // Real code sites, not just mapping arithmetic.
        for site: UInt64 in [0x2_2AC0_C334, 0x1BF4_33BD0, 0x1AD8_A12D8, 0x2_2AC0_C1B0] {
            requests.append((site, 32))
        }
        return requests
    }

    @Test("bytesAtVMA matches cfw_dsc_chunks.py across every mapping and boundary")
    func bytesMatchPython() throws {
        let pristine = try #require(DSCFixture.pristine, DSCFixture.missing)
        try #require(DSCFixture.python != nil)

        let chunks = try DSCChunkSet(directory: pristine)
        let requests = probeRequests(for: chunks)

        let requestFile = FileManager.default.temporaryDirectory
            .appendingPathComponent("dsc_probe_requests.json")
        try JSONSerialization
            .data(withJSONObject: requests.map { [$0.0, UInt64($0.1)] })
            .write(to: requestFile)

        let reference = try JSONDecoder().decode(
            [PythonBytes].self,
            from: PythonOracle.run("bytes", directory: pristine, extra: [requestFile.path])
        )
        #expect(reference.count == requests.count)

        var boundaryChecks = 0
        for theirs in reference {
            let mine = try chunks.bytesAtVMA(theirs.vma, length: theirs.length)
            #expect(mine.hex == theirs.bytes, "bytes differ at 0x\(String(theirs.vma, radix: 16))")

            let located = try #require(chunks.findChunk(forVMA: theirs.vma))
            #expect(located.chunkURL.lastPathComponent == theirs.chunk)
            #expect(located.fileOffset == theirs.file_offset)

            if let mapping = chunks.mapping(forVMA: theirs.vma),
               theirs.vma + UInt64(theirs.length) == mapping.endAddress
            {
                boundaryChecks += 1
            }
        }
        print("[bytes] \(reference.count) reads agreed, \(boundaryChecks) of them ending exactly on a mapping boundary")
        #expect(boundaryChecks >= 2)
    }

    @Test("A read or write that leaves its chunk is refused, not truncated")
    func boundaryCrossingIsRefused() throws {
        let pristine = try #require(DSCFixture.pristine, DSCFixture.missing)
        let chunks = try DSCChunkSet(directory: pristine)
        let mapping = try #require(chunks.mappings.first { $0.size > 64 })
        let lastFour = mapping.endAddress - 4

        // Reading past the end of a mapping is not a short read, it is a
        // different chunk's bytes. Every API has to say so.
        #expect(throws: DSCError.self) {
            _ = try chunks.readAtVMA(lastFour, length: 64)
        }
        let short = try chunks.readAtVMA(lastFour, length: 64, allowShort: true)
        #expect(short.count == 4)

        #expect(throws: DSCError.self) {
            _ = try chunks.write(at: lastFour, Data(repeating: 0, count: 64))
        }
        #expect(throws: DSCError.self) {
            _ = try chunks.bytesAtVMA(chunks.addressRange.upperBound + 0x1000, length: 4)
        }
        // And `bytesAtVMA` itself, at the same boundary — the case the suite
        // used to name but never exercise.
        #expect(throws: DSCError.self) {
            _ = try chunks.bytesAtVMA(lastFour, length: 64)
        }
        #expect(try chunks.bytesAtVMA(lastFour, length: 4).count == 4)
    }

    /// The reference Python bounds-checks only the first byte of a read, then
    /// reads `length` raw bytes from the file. So a read that starts near the
    /// end of a mapping comes back padded with whatever follows in the file,
    /// presented as the bytes at those virtual addresses. This is the one place
    /// the Swift deliberately diverges, and the test pins both halves: what the
    /// Python returns, and that the Swift refuses it.
    @Test("An over-running read returns the chunk's signature in Python, and throws here")
    func overrunningReadIsRefusedUnlikeThePython() throws {
        let pristine = try #require(DSCFixture.pristine, DSCFixture.missing)
        try #require(DSCFixture.python != nil)

        let chunks = try DSCChunkSet(directory: pristine)
        // 0x1800BBFFC is four bytes before the end of the main chunk's first
        // mapping. The next mapping starts at 0x180400000 — a 3.3 MB hole — so
        // bytes 4..63 of a 64-byte read correspond to no virtual address.
        let overrun: UInt64 = 0x1_800B_BFFC
        let mapping = try #require(chunks.mapping(forVMA: overrun))
        #expect(mapping.endAddress == overrun + 4)

        #expect(throws: DSCError.self) {
            _ = try chunks.bytesAtVMA(overrun, length: 64)
        }

        let requestFile = FileManager.default.temporaryDirectory
            .appendingPathComponent("dsc_overrun_request.json")
        try JSONSerialization
            .data(withJSONObject: [[overrun, UInt64(64)]])
            .write(to: requestFile)
        let theirs = try JSONDecoder().decode(
            [PythonBytes].self,
            from: PythonOracle.run("bytes", directory: pristine, extra: [requestFile.path])
        )
        let pythonBytes = try #require(theirs.first).bytes
        #expect(pythonBytes.count == 128, "the Python returns all 64 bytes without complaint")
        // Bytes 4.. are the chunk's own CS_SuperBlob, not code.
        #expect(pythonBytes.contains("fade0cc0"))

        // The four bytes that really are at that address still read fine.
        let inBounds = try chunks.bytesAtVMA(overrun, length: 4)
        #expect(pythonBytes.hasPrefix(inBounds.hex))
        print("[overrun] python returned 64 bytes at 0x\(String(overrun, radix: 16)): \(pythonBytes.prefix(48))…")
        print("[overrun] swift threw; its in-bounds 4 bytes are \(inBounds.hex)")
    }

    @Test("resolveLocalSymbol matches the Python and ipsw")
    func localSymbolMatchesReferences() throws {
        let pristine = try #require(DSCFixture.pristine, DSCFixture.missing)
        try #require(DSCFixture.python != nil)

        let chunks = try DSCChunkSet(directory: pristine)
        let name = "_kern_SwapEnd"
        let mine = try #require(try chunks.resolveLocalSymbol(name))

        struct Answer: Decodable { let address: UInt64 }
        let theirs = try JSONDecoder().decode(
            Answer.self,
            from: PythonOracle.run("local_symbol", directory: pristine, extra: [name])
        )
        #expect(mine == theirs.address)
        print("[local symbol] \(name) = 0x\(String(mine, radix: 16)) (python: 0x\(String(theirs.address, radix: 16)))")

        // A name that is not in the table is `nil`, and that is a different
        // answer from the table not being there — see
        // `missingLocalSymbolTableIsNotAMissingSymbol`.
        #expect(try chunks.resolveLocalSymbol("_definitely_not_a_symbol_xyz") == nil)
    }

    /// The `try?` this replaced spelled "I could not open the table" and "that
    /// symbol does not exist" the same way, as `nil`. The Python raises
    /// `FileNotFoundError`; so does this, in its own vocabulary.
    @Test("A missing local symbol table is not the same answer as a missing symbol")
    func missingLocalSymbolTableIsNotAMissingSymbol() throws {
        _ = try #require(DSCFixture.pristine, DSCFixture.missing)

        let clone = try DSCFixture.cloneCache(named: "symbols_removed")
        defer { DSCFixture.discard(clone) }
        try FileManager.default.removeItem(
            at: clone.appendingPathComponent("dyld_shared_cache_arm64e.symbols")
        )

        let chunks = try DSCChunkSet(directory: clone)
        #expect(throws: DSCError.self) {
            _ = try chunks.resolveLocalSymbol("_kern_SwapEnd")
        }
        #expect(throws: DSCError.self) {
            _ = try chunks.resolveLocalSymbol("_definitely_not_a_symbol_xyz")
        }

        // And the resolver built on the same cache says so rather than
        // reporting entry points with no siblings.
        let resolver = try DSCSymbolResolver(
            mainCacheURL: clone.appendingPathComponent("dyld_shared_cache_arm64e")
        )
        #expect(!resolver.hasLocalSymbols)
        #expect(throws: DSCError.self) { try resolver.requireLocalSymbols() }
        #expect(throws: DSCError.self) {
            _ = try resolver.address(
                of: "_kern_SwapEnd",
                inImage: "/System/Library/PrivateFrameworks/IOMobileFramebuffer.framework/IOMobileFramebuffer"
            )
        }
        print("[symbols missing] resolveLocalSymbol and the resolver both report the absent table")
    }

    /// The two helpers P1.3's `hv_vmm` and canonical-site finders are built on:
    /// a C-string sweep of the executable mappings, and the walk back from an
    /// address to the image that owns it.
    @Test("String search and image lookup match cfw_dsc_chunks.py")
    func searchHelpersMatchPython() throws {
        let pristine = try #require(DSCFixture.pristine, DSCFixture.missing)
        try #require(DSCFixture.python != nil)

        let chunks = try DSCChunkSet(directory: pristine)

        let needle = "kern.hv_vmm_present"
        let mine = try chunks.findStringVMAs(Data(needle.utf8))
        let theirs = try JSONDecoder().decode(
            [UInt64].self,
            from: PythonOracle.run("string_vmas", directory: pristine, extra: [needle])
        )
        #expect(mine.sorted() == theirs.sorted())
        #expect(!mine.isEmpty)
        print("[strings] \"\(needle)\": \(mine.count) hits, first 0x\(String(mine[0], radix: 16))")

        struct Image: Decodable {
            let header: UInt64?
            let install_name: String?
        }
        for site: UInt64 in [0x2_2AC0_C334, 0x1BF4_33BD0, 0x1AD8_A12D8] {
            let header = try #require(try chunks.findMachOHeaderBefore(site))
            let name = chunks.readInstallName(atHeaderVMA: header)
            let reference = try JSONDecoder().decode(
                Image.self,
                from: PythonOracle.run(
                    "image_at",
                    directory: pristine,
                    extra: ["0x\(String(site, radix: 16))"]
                )
            )
            #expect(header == reference.header)
            #expect(name == reference.install_name)
            print("[image] 0x\(String(site, radix: 16)) -> 0x\(String(header, radix: 16)) \(name ?? "<none>")")
        }
    }
}

// MARK: - 3.2 · Code-signature page-hash re-signing, DSC path

@Suite(.serialized, .enabled(if: DSCFixture.runs, DSCFixture.skipReason))
struct DSCCodeSignatureTests {
    private struct PythonDirectory: Decodable {
        let cd_file_off: Int
        let cd_length: Int
        let hash_offset: Int
        let hash_size: Int
        let n_code_slots: Int
        let code_limit: Int
        let page_size: Int
    }

    private struct PythonDiagnostic: Decodable {
        let chunk_path: String
        let page_index: Int
        let chunk_off: Int
        let slot_off: Int
        let sha256_before: String
        let sha256_after: String
    }

    private struct PythonPatchResult: Decodable {
        let before: String
        let diagnostics: [PythonDiagnostic]
    }

    /// A site inside `IOMobileFramebuffer`'s `__text` — a real executable page
    /// whose slot a real patch would have to re-sign.
    private let patchSite: UInt64 = 0x2_2AC0_C334

    @Test("Chunk code directories match cfw_dsc_codesign.py")
    func codeDirectoriesMatchPython() throws {
        let pristine = try #require(DSCFixture.pristine, DSCFixture.missing)
        try #require(DSCFixture.python != nil)

        let chunks = try DSCChunkSet(directory: pristine)
        let reference = try JSONDecoder().decode(
            [String: PythonDirectory?].self,
            from: PythonOracle.run("coderdirs", directory: pristine)
        )

        var compared = 0
        for url in chunks.chunkURLs {
            let mine = try DSCCodeSignature.readCodeDirectory(ofChunk: url)
            let theirs = reference[url.lastPathComponent] ?? nil
            guard let theirs else {
                #expect(mine == nil, "\(url.lastPathComponent): python found no CD, Swift did")
                continue
            }
            let mine2 = try #require(mine, "\(url.lastPathComponent): python found a CD, Swift did not")
            #expect(mine2.blobOffset == theirs.cd_file_off)
            #expect(mine2.blobLength == theirs.cd_length)
            #expect(mine2.hashOffset == theirs.hash_offset)
            #expect(mine2.hashSize == theirs.hash_size)
            #expect(mine2.codeSlotCount == theirs.n_code_slots)
            #expect(mine2.codeLimit == theirs.code_limit)
            #expect(mine2.pageSize == theirs.page_size)
            compared += 1
        }
        print("[code directories] \(compared) chunk signatures agreed with the Python")
        #expect(compared > 70)
    }

    /// The DSC path's stated invariants: 16 KiB pages, a single SHA-256 code
    /// directory, and no short tail slot.
    @Test("Every signed chunk is 16 KiB paged, SHA-256, and chunk-aligned")
    func dscPathShapeHolds() throws {
        let pristine = try #require(DSCFixture.pristine, DSCFixture.missing)
        let chunks = try DSCChunkSet(directory: pristine)
        var checked = 0
        for url in chunks.chunkURLs {
            guard let directory = try DSCCodeSignature.readCodeDirectory(ofChunk: url) else {
                continue
            }
            #expect(directory.pageSize == 16384, "\(url.lastPathComponent) page size")
            #expect(directory.hashSize == 32, "\(url.lastPathComponent) hash size")
            // Chunk-aligned: the last slot covers a whole page, so unlike the
            // independent Mach-O path there is no short tail to special-case.
            let covered = directory.codeSlotCount * directory.pageSize
            #expect(
                covered == directory.codeLimit,
                "\(url.lastPathComponent) has a short tail slot: codeLimit \(directory.codeLimit), slots cover \(covered)"
            )
            checked += 1
        }
        print("[shape] \(checked) chunks: 16 KiB pages, SHA-256, no short tail slot")
        #expect(checked > 70)
    }

    /// The gate from the plan: patch one byte, re-sign with each
    /// implementation in its own clone, and require the two caches to come out
    /// byte-identical over the page and over the whole code directory.
    @Test("Swift and Python re-signing produce byte-identical slot hashes")
    func reSigningMatchesPythonByteForByte() throws {
        _ = try #require(DSCFixture.pristine, DSCFixture.missing)
        try #require(DSCFixture.python != nil)

        let swiftSide = try DSCFixture.cloneCache(named: "resign_swift")
        let pythonSide = try DSCFixture.cloneCache(named: "resign_python")
        defer { DSCFixture.discard(swiftSide, pythonSide) }

        // The replacement is a real instruction shape — `mov w3, #0x588`, the
        // immediate `cfw_patch_iomfb_swapend` writes — not a byte pattern
        // chosen to be easy.
        let replacement = Data([0x03, 0xB1, 0x80, 0x52])

        // Python: write through its own writer, then re-sign.
        let pythonResult = try JSONDecoder().decode(
            PythonPatchResult.self,
            from: PythonOracle.run(
                "patch_and_reattest",
                directory: pythonSide,
                extra: ["0x\(String(patchSite, radix: 16))", replacement.hex]
            )
        )
        #expect(pythonResult.diagnostics.count == 1)
        let theirs = try #require(pythonResult.diagnostics.first)

        // Swift: same write, same re-sign — and the re-sign is driven by what
        // the write itself recorded, not by an address repeated by hand.
        let chunks = try DSCChunkSet(directory: swiftSide)
        let originalBytes = try chunks.bytesAtVMA(patchSite, length: replacement.count)
        #expect(originalBytes.hex == pythonResult.before)
        let span = try chunks.write(at: patchSite, replacement)
        #expect(span == DSCWriteSpan(vma: patchSite, length: 4))
        #expect(chunks.recordedWrites == [span])

        var log: [String] = []
        let result = try DSCCodeSignature.reattestRecordedWrites(
            in: chunks,
            log: { log.append($0) }
        )
        #expect(result.updated.count == 1)
        #expect(result.isFullyAttested)
        let mine = try #require(result.updated.first)

        // The hashes themselves.
        #expect(mine.pageIndex == theirs.page_index)
        #expect(mine.chunkOffset == theirs.chunk_off)
        #expect(mine.slotOffset == theirs.slot_off)
        #expect(mine.hashBefore.hex == theirs.sha256_before)
        #expect(mine.hashAfter.hex == theirs.sha256_after)
        #expect(mine.chunkURL.lastPathComponent == URL(fileURLWithPath: theirs.chunk_path).lastPathComponent)

        // And the bytes on disk, which is the claim that actually matters.
        let chunkName = mine.chunkURL.lastPathComponent
        let directory = try #require(
            try DSCCodeSignature.readCodeDirectory(ofChunk: mine.chunkURL)
        )
        let swiftSlots = try DSCChunkSet.read(
            url: swiftSide.appendingPathComponent(chunkName),
            offset: UInt64(directory.blobOffset),
            length: directory.blobLength
        )
        let pythonSlots = try DSCChunkSet.read(
            url: pythonSide.appendingPathComponent(chunkName),
            offset: UInt64(directory.blobOffset),
            length: directory.blobLength
        )
        #expect(swiftSlots == pythonSlots, "the whole code directory blob must match")

        let swiftPage = try DSCChunkSet.read(
            url: swiftSide.appendingPathComponent(chunkName),
            offset: UInt64(mine.chunkOffset),
            length: directory.pageSize
        )
        let pythonPage = try DSCChunkSet.read(
            url: pythonSide.appendingPathComponent(chunkName),
            offset: UInt64(mine.chunkOffset),
            length: directory.pageSize
        )
        #expect(swiftPage == pythonPage, "the patched page must match")

        // The stored slot has to be the digest of the page as it now stands.
        let (computed, stored) = try DSCCodeSignature.pageHashes(
            chunkURL: mine.chunkURL,
            pageIndex: mine.pageIndex,
            directory: directory
        )
        #expect(computed == stored)
        #expect(stored.hex == theirs.sha256_after)

        print("[re-sign] chunk \(chunkName) page \(mine.pageIndex) slot @0x\(String(mine.slotOffset, radix: 16))")
        print("[re-sign] swift  \(mine.hashAfter.hex)")
        print("[re-sign] python \(theirs.sha256_after)")
        for line in log { print(line) }
    }

    /// The finding all three verifiers reached independently, pinned.
    ///
    /// Eight bytes — `mov w0, #0; ret`, exactly what `cfw_patch_camera_dsc.py`
    /// writes at each of its six function entries — placed so four of them land
    /// on page 2563 and four on page 2564. Re-attesting the address alone
    /// covers one page; the other keeps its original slot hash, and the guest
    /// dies on the first demand-page-in of it. The Python does exactly that;
    /// this checks the Swift no longer can.
    @Test("A write across a page boundary re-attests both pages, where the Python attests one")
    func pageStraddlingWriteAttestsEveryDirtiedPage() throws {
        _ = try #require(DSCFixture.pristine, DSCFixture.missing)
        try #require(DSCFixture.python != nil)

        let swiftSide = try DSCFixture.cloneCache(named: "straddle_swift")
        let pythonSide = try DSCFixture.cloneCache(named: "straddle_python")
        defer { DSCFixture.discard(swiftSide, pythonSide) }

        // 0x22AC0FFFC is file offset 0x280FFFC of chunk .38 — the last four
        // bytes of page 2563. Eight bytes from there end four bytes into 2564.
        let straddle: UInt64 = 0x2_2AC0_FFFC
        let stub = Data([0x00, 0x00, 0x80, 0x52, 0xC0, 0x03, 0x5F, 0xD6])
        let chunkName = "dyld_shared_cache_arm64e.38"
        let firstPage = 2563
        let secondPage = 2564

        // Swift: write, then re-attest from what the write recorded.
        let chunks = try DSCChunkSet(directory: swiftSide)
        let span = try chunks.write(at: straddle, stub)
        #expect(span.length == 8)
        let (writtenChunk, writtenRange) = try chunks.fileRange(of: span)
        #expect(writtenChunk.lastPathComponent == chunkName)
        #expect(writtenRange == 0x280_FFFC ..< 0x281_0004)

        var log: [String] = []
        let result = try DSCCodeSignature.reattestRecordedWrites(
            in: chunks,
            log: { log.append($0) }
        )
        #expect(result.updated.map(\.pageIndex) == [firstPage, secondPage])
        #expect(result.isFullyAttested)

        // Both pages, checked by the reference implementation reading the code
        // directory itself — not by this code agreeing with itself.
        for page in [firstPage, secondPage] {
            let state = try PythonOracle.slotState(
                directory: swiftSide,
                chunk: chunkName,
                page: page
            )
            #expect(state.isAttested, "swift left page \(page) stale: \(state.stored)")
            print("[straddle swift] page \(page) stored \(state.stored.prefix(16))… == computed")
        }

        // The Python, told the same address, covers page 2563 and leaves 2564
        // stale. This is the bug in the reference, reproduced, so the
        // divergence is on the record rather than assumed.
        let pythonResult = try JSONDecoder().decode(
            PythonPatchResult.self,
            from: PythonOracle.run(
                "patch_and_reattest",
                directory: pythonSide,
                extra: ["0x\(String(straddle, radix: 16))", stub.hex]
            )
        )
        #expect(pythonResult.diagnostics.map(\.page_index) == [firstPage])

        let pythonFirst = try PythonOracle.slotState(
            directory: pythonSide, chunk: chunkName, page: firstPage
        )
        let pythonSecond = try PythonOracle.slotState(
            directory: pythonSide, chunk: chunkName, page: secondPage
        )
        #expect(pythonFirst.isAttested)
        #expect(
            !pythonSecond.isAttested,
            "the Python reference unexpectedly covered the second page too"
        )
        print("[straddle python] page \(firstPage) attested, page \(secondPage) stored "
            + "\(pythonSecond.stored.prefix(16))… vs computed \(pythonSecond.computed.prefix(16))… — STALE")

        // The bytes themselves still agree; only the attested page set differs.
        let swiftBytes = try DSCChunkSet.read(
            url: swiftSide.appendingPathComponent(chunkName),
            offset: 0x280_FFFC,
            length: 8
        )
        let pythonBytes = try DSCChunkSet.read(
            url: pythonSide.appendingPathComponent(chunkName),
            offset: 0x280_FFFC,
            length: 8
        )
        #expect(swiftBytes == stub)
        #expect(swiftBytes == pythonBytes)
        for line in log { print(line) }
    }

    /// A span may cross from one mapping into the next when the two are
    /// contiguous in address *and* in file offset inside the same chunk — 19 of
    /// the 62 adjacent mapping pairs on this cache are. The old guard compared
    /// mapping start addresses and refused all of them, where the Python wrote
    /// them happily. This one is accepted, and matches the Python byte for
    /// byte; the case where the file offsets break is still refused.
    @Test("A write across contiguous mappings of one chunk is written, and matches the Python")
    func contiguousMappingSeamIsWritable() throws {
        _ = try #require(DSCFixture.pristine, DSCFixture.missing)
        try #require(DSCFixture.python != nil)

        let swiftSide = try DSCFixture.cloneCache(named: "seam_swift")
        let pythonSide = try DSCFixture.cloneCache(named: "seam_python")
        defer { DSCFixture.discard(swiftSide, pythonSide) }

        // 0x1E00DFFFE is two bytes before the end of the first mapping of
        // .25.dylddata; the next mapping continues at file offset 0x4000 of the
        // same file. Four bytes therefore cross both a mapping seam and a
        // 16 KiB page boundary.
        let seam: UInt64 = 0x1_E00D_FFFE
        let value = Data([0x11, 0x22, 0x33, 0x44])
        let chunkName = "dyld_shared_cache_arm64e.25.dylddata"

        let chunks = try DSCChunkSet(directory: swiftSide)
        let mapping = try #require(chunks.mapping(forVMA: seam))
        let next = try #require(chunks.mapping(forVMA: mapping.endAddress))
        #expect(next.chunkURL.lastPathComponent == chunkName)
        #expect(next.fileOffset == mapping.fileOffset + mapping.size)

        let span = try chunks.write(at: seam, value)
        let result = try DSCCodeSignature.reattestRecordedWrites(in: chunks, log: nil)
        #expect(span.length == 4)
        #expect(result.isFullyAttested)
        // 0x3FFE..0x4001 spans pages 0 and 1 of the chunk.
        #expect(result.updated.map(\.pageIndex) + result.alreadyAttested.map(\.pageIndex) == [0, 1])

        try PythonOracle.run(
            "write_at",
            directory: pythonSide,
            extra: ["0x\(String(seam, radix: 16))", value.hex]
        )
        struct Bytes: Decodable { let bytes: String }
        let theirs = try JSONDecoder().decode(
            Bytes.self,
            from: PythonOracle.run(
                "file_bytes",
                directory: pythonSide,
                extra: [chunkName, "0x3ffe", "4"]
            )
        )
        let mine = try DSCChunkSet.read(
            url: swiftSide.appendingPathComponent(chunkName),
            offset: 0x3FFE,
            length: 4
        )
        #expect(mine.hex == theirs.bytes)
        #expect(mine == value)
        print("[seam] 0x\(String(seam, radix: 16)) -> \(chunkName)@0x3ffe: swift \(mine.hex), python \(theirs.bytes)")

        for page in [0, 1] {
            let state = try PythonOracle.slotState(
                directory: swiftSide, chunk: chunkName, page: page
            )
            #expect(state.isAttested, "page \(page) left stale")
        }

        // A seam where the file offsets do not continue is still a refusal.
        let crossChunk = try #require(
            chunks.mappings.first { mapping in
                guard let next = chunks.mapping(forVMA: mapping.endAddress) else { return false }
                return next.chunkURL != mapping.chunkURL
            }
        )
        #expect(throws: DSCError.self) {
            _ = try chunks.write(at: crossChunk.endAddress - 2, Data([0, 0, 0, 0]))
        }
    }

    /// `8eb6c8b` fixed a patcher that did not recognise its own output. The
    /// same trap applies here: a second re-sign of an already-attested page has
    /// to be a no-op, not a rewrite and not an error.
    @Test("Re-signing twice is a no-op the second time")
    func reSigningIsIdempotent() throws {
        _ = try #require(DSCFixture.pristine, DSCFixture.missing)

        let clone = try DSCFixture.cloneCache(named: "resign_idempotent")
        defer { DSCFixture.discard(clone) }

        let chunks = try DSCChunkSet(directory: clone)
        let span = try chunks.write(at: patchSite, Data([0x03, 0xB1, 0x80, 0x52]))

        let first = try DSCCodeSignature.reattest(in: chunks, modifiedSpans: [span], log: nil)
        #expect(first.updated.count == 1)
        #expect(first.alreadyAttested.isEmpty)

        let second = try DSCCodeSignature.reattest(in: chunks, modifiedSpans: [span], log: nil)
        #expect(second.updated.isEmpty, "a second re-sign rewrote a slot that already matched")
        #expect(second.alreadyAttested.count == 1, "and it has to say so, not just return nothing")
        #expect(second.isFullyAttested)

        // Several addresses inside one page still cost exactly one slot.
        let third = try DSCCodeSignature.reattest(
            in: chunks,
            modifiedSpans: [patchSite, patchSite + 4, patchSite + 8].map(DSCWriteSpan.byte(at:)),
            log: nil
        )
        #expect(third.updated.isEmpty)
        #expect(third.alreadyAttested.count == 1)
        print("[idempotence] first run rewrote 1 slot; second and third rewrote 0 and reported 1 already correct")
    }

    /// Every early return used to yield `[]` under the default `log: nil`, so
    /// "I skipped an address I could not map", "everything already matched" and
    /// "you passed me nothing" were the same value. They are three different
    /// values now, and the default log is no longer silent.
    @Test("A skipped page is distinguishable from nothing to do")
    func skipsAreReportedNotSwallowed() throws {
        let pristine = try #require(DSCFixture.pristine, DSCFixture.missing)
        let chunks = try DSCChunkSet(directory: pristine)

        let stray = try DSCCodeSignature.reattest(
            in: chunks,
            modifiedSpans: [DSCWriteSpan.byte(at: 0xDEAD_0000_0000)],
            dryRun: true,
            log: nil
        )
        #expect(stray.updated.isEmpty)
        #expect(stray.skipped.count == 1)
        #expect(!stray.isFullyAttested, "an unmapped address is not a clean run")
        if case let .addressNotMapped(vma) = stray.skipped[0].reason {
            #expect(vma == 0xDEAD_0000_0000)
        } else {
            Issue.record("wrong skip reason: \(stray.skipped[0].reason)")
        }

        let nothing = try DSCCodeSignature.reattest(
            in: chunks,
            modifiedSpans: [] as [DSCWriteSpan],
            dryRun: true,
            log: nil
        )
        #expect(nothing.skipped.isEmpty)
        #expect(nothing.isFullyAttested, "nothing to do is a clean run")

        // A span that runs off the end of its chunk is its own reason.
        let mapping = try #require(chunks.mappings.first { $0.size > 64 })
        let overrun = try DSCCodeSignature.reattest(
            in: chunks,
            modifiedSpans: [DSCWriteSpan(vma: mapping.endAddress - 2, length: 64)],
            dryRun: true,
            log: nil
        )
        #expect(overrun.skipped.count == 1)
        if case .spanNotAddressable = overrun.skipped[0].reason {} else {
            Issue.record("wrong skip reason: \(overrun.skipped[0].reason)")
        }

        // And the default log says all of it out loud, like the Python's
        // verbose=True does.
        var spoken: [String] = []
        _ = try DSCCodeSignature.reattest(
            in: chunks,
            modifiedSpans: [DSCWriteSpan.byte(at: 0xDEAD_0000_0000)],
            dryRun: true,
            log: { spoken.append($0) }
        )
        #expect(spoken.contains { $0.contains("not mapped in any chunk") })
        for line in spoken { print("[skip log] \(line)") }
    }

    @Test("A dry run computes the same hash it would have written, and writes nothing")
    func dryRunWritesNothing() throws {
        _ = try #require(DSCFixture.pristine, DSCFixture.missing)

        let clone = try DSCFixture.cloneCache(named: "resign_dryrun")
        defer { DSCFixture.discard(clone) }

        let chunks = try DSCChunkSet(directory: clone)
        try chunks.write(at: patchSite, Data([0x03, 0xB1, 0x80, 0x52]))

        let dry = try DSCCodeSignature.reattestRecordedWrites(
            in: chunks,
            dryRun: true,
            log: nil
        )
        #expect(dry.updated.count == 1)
        let record = try #require(dry.updated.first)

        let directory = try #require(
            try DSCCodeSignature.readCodeDirectory(ofChunk: record.chunkURL)
        )
        let (_, storedAfterDryRun) = try DSCCodeSignature.pageHashes(
            chunkURL: record.chunkURL,
            pageIndex: record.pageIndex,
            directory: directory
        )
        #expect(storedAfterDryRun == record.hashBefore, "a dry run must not touch the slot")

        let wet = try DSCCodeSignature.reattestRecordedWrites(in: chunks, log: nil)
        #expect(wet.updated.first?.hashAfter == record.hashAfter)
    }
}

// MARK: - 3.3 · Symbol resolution

@Suite(.serialized, .enabled(if: DSCFixture.runs, DSCFixture.skipReason))
struct DSCSymbolResolverTests {
    private static let neutrinoCore =
        "/System/Library/PrivateFrameworks/NeutrinoCore.framework/NeutrinoCore"
    private static let avfCapture =
        "/System/Library/PrivateFrameworks/AVFCapture.framework/AVFCapture"
    private static let ioMobileFramebuffer =
        "/System/Library/PrivateFrameworks/IOMobileFramebuffer.framework/IOMobileFramebuffer"

    /// The complete set the three patchers look up.
    ///
    /// `cfw_patch_camera_dsc.py` names six ObjC methods; `cfw_patch_iomfb_swapend.py`
    /// names `_kern_SwapEnd`; `cfw_patch_iomfb_force_kern.py` does not name any,
    /// it discovers every `_IOMobileFramebufferSwap*` with a `_kern_` sibling,
    /// so the four pairs that discovery finds on this cache are listed here.
    private static let required: [(image: String, symbols: [String])] = [
        (neutrinoCore, [
            "+[_NUStyleTransferProcessor processWithInputs:arguments:output:error:]",
            "+[_NUStyleTransferThumbnailProcessor processWithInputs:arguments:output:error:]",
            "+[_NUStyleTransferApplyProcessor processWithInputs:arguments:output:error:]",
            "+[_NUStyleTransferLearnProcessor processWithInputs:arguments:output:error:]",
            "+[_NUStyleTransferInterpolateProcessor processWithInputs:arguments:output:error:]",
        ]),
        (avfCapture, [
            "+[AVCaptureDevice authorizationStatusForMediaType:]",
        ]),
        (ioMobileFramebuffer, [
            "_kern_SwapEnd",
            "_kern_SwapBegin",
            "_kern_SwapSetLayer",
            "_kern_SwapSetLayerEDRCompensation",
            "_IOMobileFramebufferSwapBegin",
            "_IOMobileFramebufferSwapEnd",
            "_IOMobileFramebufferSwapSetLayer",
            "_IOMobileFramebufferSwapSetLayerEDRCompensation",
        ]),
    ]

    /// `ipsw dyld symaddr <cache> --image <image>` for one image, parsed into
    /// name → address. The per-symbol form of that command is what times out on
    /// this cache; the whole-image dump answers in under a second.
    private func ipswSymbols(image: String, cache: URL) throws -> [String: UInt64] {
        guard let ipsw = DSCFixture.ipsw else { return [:] }
        let result = try Subprocess.run(
            executable: ipsw,
            arguments: [
                "dyld", "symaddr",
                cache.appendingPathComponent("dyld_shared_cache_arm64e").path,
                "--image", image,
            ]
        )
        guard result.status == 0 else { return [:] }

        var symbols: [String: UInt64] = [:]
        for rawLine in result.stdout.split(separator: "\n") {
            // Strip SGR colour codes, then split "0xADDR:\t(kind)\tname\timage".
            let line = rawLine.replacing(/\u{1B}\[[0-9;]*m/, with: "")
            guard let colon = line.firstIndex(of: ":") else { continue }
            let addressText = line[line.startIndex ..< colon].trimmingCharacters(in: .whitespaces)
            guard addressText.hasPrefix("0x"),
                  let address = UInt64(addressText.dropFirst(2), radix: 16)
            else { continue }
            var rest = line[line.index(after: colon)...]
                .trimmingCharacters(in: .whitespaces)
            guard rest.hasPrefix("(") , let close = rest.firstIndex(of: ")") else { continue }
            rest = String(rest[rest.index(after: close)...]).trimmingCharacters(in: .whitespaces)
            // The name may be followed by a tab and the image name; ObjC method
            // names contain spaces, so split on tabs only.
            let name = rest.split(separator: "\t").first.map(String.init) ?? rest
            if symbols[name] == nil { symbols[name] = address }
        }
        return symbols
    }

    @Test("Every symbol the three DSC patchers look up resolves, and agrees with ipsw")
    func requiredSymbolsResolveAndAgree() throws {
        let pristine = try #require(DSCFixture.pristine, DSCFixture.missing)
        let resolver = try DSCSymbolResolver(
            mainCacheURL: pristine.appendingPathComponent("dyld_shared_cache_arm64e")
        )
        #expect(resolver.hasLocalSymbols)

        var agreed = 0
        var unconfirmed: [String] = []
        for (image, wanted) in Self.required {
            let resolved = try resolver.addresses(of: wanted, inImage: image)
            #expect(resolved.count == wanted.count)

            let reference = try ipswSymbols(image: image, cache: pristine)
            for name in wanted {
                let mine = try #require(resolved[name])
                #expect(mine != 0)
                if let theirs = reference[name] {
                    #expect(
                        mine == theirs,
                        "\(name): swift 0x\(String(mine, radix: 16)) vs ipsw 0x\(String(theirs, radix: 16))"
                    )
                    agreed += 1
                    print("[symbol] \(name) = 0x\(String(mine, radix: 16)) (ipsw agrees)")
                } else {
                    unconfirmed.append(name)
                    print("[symbol] \(name) = 0x\(String(mine, radix: 16)) (ipsw did not report it)")
                }
            }
        }
        print("[symbols] \(agreed) confirmed against ipsw, \(unconfirmed.count) unconfirmed")
        #expect(agreed >= 13, "ipsw confirmed only \(agreed) symbols")
    }

    @Test("The force-kern discovery shape is reproduced without ipsw")
    func forceKernPairsAreDiscoverable() throws {
        let pristine = try #require(DSCFixture.pristine, DSCFixture.missing)
        let resolver = try DSCSymbolResolver(
            mainCacheURL: pristine.appendingPathComponent("dyld_shared_cache_arm64e")
        )
        try resolver.requireLocalSymbols()

        let publicPrefix = "_IOMobileFramebufferSwap"
        let all = try resolver.symbols(inImage: Self.ioMobileFramebuffer)
        let entryPoints = try resolver.symbols(
            inImage: Self.ioMobileFramebuffer,
            withPrefix: publicPrefix
        )

        var pairs: [(String, UInt64, String, UInt64)] = []
        for (name, address) in entryPoints.sorted(by: { $0.key < $1.key }) {
            let sibling = "_kern_Swap" + name.dropFirst(publicPrefix.count)
            guard let kern = all[sibling] else { continue }
            pairs.append((name, address, sibling, kern.address))
        }

        // `cfw_patch_iomfb_force_kern.py` refuses to ship unless these three
        // are covered, so the resolver has to find all three without ipsw.
        for required in ["SwapBegin", "SwapEnd", "SwapSetLayer"] {
            #expect(
                pairs.contains { $0.0 == publicPrefix + required.dropFirst(4) },
                "missing entry point for \(required)"
            )
        }
        for pair in pairs {
            print("[force-kern] \(pair.0) 0x\(String(pair.1, radix: 16)) -> \(pair.2) 0x\(String(pair.3, radix: 16))")
        }
        #expect(pairs.count >= 3)
    }

    @Test("A missing symbol and a missing image both fail loudly")
    func missingLookupsThrow() throws {
        let pristine = try #require(DSCFixture.pristine, DSCFixture.missing)
        let resolver = try DSCSymbolResolver(
            mainCacheURL: pristine.appendingPathComponent("dyld_shared_cache_arm64e")
        )
        #expect(throws: DSCError.self) {
            _ = try resolver.address(
                of: "_this_symbol_does_not_exist",
                inImage: Self.ioMobileFramebuffer
            )
        }
        #expect(throws: DSCError.self) {
            _ = try resolver.symbols(inImage: "/System/Library/Nope.framework/Nope")
        }
    }
}
