import CryptoKit
import Foundation
import MachOKit
import Synchronization
import VPhonePatchKit

public enum DyldSharedCacheArm64eX1BootstrapPatcher {
    struct Write: Sendable {
        let address: UInt64
        let word: UInt32
    }

    /// One image's plan, reduced to its writes: a full cache holds tens of
    /// millions of rewrites, too many to keep as patch records.
    struct ImagePlan: Sendable {
        let writes: [Write]
        let unvisitedCandidates: Int
    }

    /// Cold-boot evidence for this closure is recorded in Research/0_binary_patch_comparison.md.
    static let bootstrapImages: Set<String> = [
        "/usr/lib/libSystem.B.dylib",
        "/usr/lib/system/libsystem_kernel.dylib",
        "/usr/lib/system/libsystem_platform.dylib",
        "/usr/lib/system/libsystem_pthread.dylib",
        "/usr/lib/system/libsystem_c.dylib",
        "/usr/lib/system/libsystem_sanitizers.dylib",
        "/usr/lib/system/libsystem_malloc.dylib",
        "/usr/lib/system/libsystem_featureflags.dylib",
        "/usr/lib/system/libcorecrypto.dylib",
        "/usr/lib/dyld",
        "/usr/lib/system/libdyld.dylib",
        "/usr/lib/system/libsystem_blocks.dylib",
        "/usr/lib/system/libdispatch.dylib",
        "/usr/lib/libobjc.A.dylib",
        "/usr/lib/system/libmacho.dylib",
        "/usr/lib/system/libxpc.dylib",
        "/usr/lib/system/libsystem_trace.dylib",
        "/usr/lib/system/libsystem_darwin.dylib",
        "/usr/lib/objc/libobjcMsgSend.dylib",
        "/usr/lib/objc/libobjcMsgSend5.dylib",
        "/usr/lib/system/libsystem_containermanager.dylib",
        "/usr/lib/system/libsystem_sandbox.dylib",
        "/usr/lib/libc++.1.dylib",
        "/usr/lib/libc++abi.dylib",
        "/usr/lib/swift/libswiftCore.dylib",
        "/usr/lib/swift/libswift_Concurrency.dylib",
        "/usr/lib/system/libsystem_notify.dylib",
        "/usr/lib/system/libsystem_info.dylib",
        "/usr/lib/system/libsystem_collections.dylib",
        "/usr/lib/system/libsystem_coreservices.dylib",
        "/usr/lib/system/libsystem_asl.dylib",
        "/usr/lib/system/libsystem_configuration.dylib",
        "/System/Library/Frameworks/CoreFoundation.framework/CoreFoundation",
        "/System/Library/Frameworks/Foundation.framework/Foundation",
        "/System/Library/Frameworks/Network.framework/Network",
        "/System/Library/Frameworks/IOKit.framework/Versions/A/IOKit",
        "/System/Library/PrivateFrameworks/APFS.framework/APFS",
        "/usr/lib/swift/libswiftDispatch.dylib",
    ]

    public static func patch(
        directory: URL,
        dryRun: Bool = false,
        captureUndo: Bool = false,
        onUndo: (DyldSharedCacheUndoLog) -> Void = { _ in },
        log: @escaping (String) -> Void = { print($0) },
    ) throws {
        try lower(
            directory: directory, dryRun: dryRun, captureUndo: captureUndo, onUndo: onUndo, log: log,
            patchID: FirmwareGuestSystemPatchSet.arm64eX1CacheBootstrap, label: "X1 bootstrap cache",
        ) { paths in
            let missing = bootstrapImages.subtracting(paths)
            guard missing.isEmpty else {
                throw PatcherError.invalidFormat(
                    "required X1 bootstrap cache images are missing: \(missing.sorted().joined(separator: ", "))",
                )
            }
            return bootstrapImages
        } finish: { chunks, selected in
            let coreCrypto = selected.first { $0.path == "/usr/lib/system/libcorecrypto.dylib" }!
            try refreshCoreCryptoIntegrity(at: coreCrypto.address, in: chunks, log: log)
        }
    }

    /// Lowers every X1 image the bootstrap closure leaves to launchd's
    /// on-demand handler. That handler is one thread in PID 1 and patches a
    /// private page copy per process, so each process re-faults every site it
    /// runs; SwiftUI-heavy extensions then exhaust FrontBoard's watchdog. An
    /// image this planner cannot lower stays on the on-demand path.
    public static func patchRemaining(
        directory: URL,
        dryRun: Bool = false,
        captureUndo: Bool = false,
        onUndo: (DyldSharedCacheUndoLog) -> Void = { _ in },
        log: @escaping (String) -> Void = { print($0) },
    ) throws {
        try lower(
            directory: directory, dryRun: dryRun, captureUndo: captureUndo, onUndo: onUndo, log: log,
            patchID: FirmwareGuestSystemPatchSet.arm64eX1CacheRemaining, label: "X1 cache",
            skipsUnplannable: true,
        ) { paths in
            paths.subtracting(bootstrapImages)
        } finish: { _, _ in }
    }

    private static func lower(
        directory: URL,
        dryRun: Bool,
        captureUndo: Bool,
        onUndo: (DyldSharedCacheUndoLog) -> Void,
        log: @escaping (String) -> Void,
        patchID: String,
        label: String,
        skipsUnplannable: Bool = false,
        select: (Set<String>) throws -> Set<String>,
        finish: (DyldSharedCacheChunkSet, [(address: UInt64, path: String)]) throws -> Void,
    ) throws {
        let chunks = try DyldSharedCacheChunkSet(
            directory: directory,
            captureUndo: captureUndo || !dryRun,
        )
        guard chunks.mainCacheURL.lastPathComponent.hasSuffix("arm64e_x1") else {
            log("  [·] \(label): not an X1 cache")
            return
        }

        let cache = try FullDyldCache(url: chunks.mainCacheURL)
        guard let infos = cache.imageInfos else {
            throw PatcherError.invalidFormat("X1 cache has no images")
        }
        var images: [(address: UInt64, path: String)] = []
        var seen = Set<UInt64>()
        for info in infos where seen.insert(info.address).inserted {
            guard let path = info.path(in: cache) else { continue }
            images.append((info.address, path))
        }
        let wanted = try select(Set(images.map(\.path)))
        let selected = images.filter { wanted.contains($0.path) }

        // Planning only reads; each worker gets its own chunk set and Capstone
        // handle, and results keep image order so the writes are deterministic.
        let workers = max(1, min(ProcessInfo.processInfo.activeProcessorCount, selected.count))
        // Largest first, sized by the gap to the next image, so the last few
        // workers are not left with UIKitCore while the rest sit idle.
        let starts = images.map(\.address).sorted()
        var spans: [UInt64: UInt64] = [:]
        for (start, next) in zip(starts, starts.dropFirst()) { spans[start] = next - start }
        let order = selected.indices.sorted { spans[selected[$0].address, default: 0] > spans[selected[$1].address, default: 0] }
        let readers = try (0 ..< workers).map { _ in try DyldSharedCacheChunkSet(directory: directory, mappedReads: true) }
        // One decoder per worker, reused across its images: cached decodes
        // belong to the word, not to the image.
        let decodability = CustomFirmwareArm64eX1.SharedDecodability()
        let decoders = (0 ..< workers).map { _ in CustomFirmwareArm64eX1.Decoder(shared: decodability) }
        let queue = Mutex((
            next: 0,
            plans: [Result<ImagePlan, any Error>?](repeating: nil, count: selected.count),
        ))
        DispatchQueue.concurrentPerform(iterations: workers) { worker in
            // Capstone formats operands with vsnprintf, which serializes every
            // worker on the global locale's lock; a thread locale avoids it.
            let locale = newlocale(LC_NUMERIC_MASK, "C", nil)
            let previous = uselocale(locale)
            defer {
                uselocale(previous)
                freelocale(locale)
            }
            while true {
                let next = queue.withLock { state in
                    defer { state.next += 1 }
                    return state.next
                }
                guard next < order.count else { return }
                let index = order[next]
                let plan = Result {
                    let result = try planImage(at: selected[index].address, in: readers[worker], identifier: patchID,
                                               decoder: decoders[worker])
                    return ImagePlan(
                        writes: result.records.map {
                            Write(
                                address: UInt64($0.fileOffset),
                                word: $0.patchedBytes.loadLE(UInt32.self, at: 0),
                            )
                        },
                        unvisitedCandidates: result.unvisitedCandidates,
                    )
                }
                queue.withLock { $0.plans[index] = plan }
            }
        }
        let plans = queue.withLock { $0.plans }

        var writes: [Write] = []
        var unvisited = 0
        var lowered = 0
        var skipped: [String] = []
        for (image, plan) in zip(selected, plans) {
            let result: ImagePlan
            do {
                result = try plan!.get()
            } catch where skipsUnplannable {
                skipped.append(image.path)
                log("  [!] \(label): \(image.path): left to the on-demand handler: \(error)")
                continue
            }
            unvisited += result.unvisitedCandidates
            if !result.writes.isEmpty { lowered += 1 }
            writes += result.writes
            if !skipsUnplannable || !result.writes.isEmpty {
                log("  [.] \(label): \(image.path): \(result.writes.count) instructions, \(result.unvisitedCandidates) unvisited")
            }
        }
        writes.sort { $0.address < $1.address }
        log("  [*] \(label): \(selected.count) image(s), \(lowered) with X1 code, \(skipped.count) skipped, \(writes.count) rewrites, \(unvisited) unvisited candidates")
        guard !dryRun else { return }

        do {
            var index = 0
            var groups = 0
            var pageSizes: [URL: Int] = [:]
            while index < writes.count {
                let first = index
                let start = writes[index].address
                let firstChunk = try chunks.fileRange(of: .init(vma: start, length: 4)).chunkURL
                let pageSize: Int
                if let known = pageSizes[firstChunk] {
                    pageSize = known
                } else {
                    guard let directory = try DyldSharedCacheCodeSignature.readCodeDirectory(ofChunk: firstChunk) else {
                        throw PatcherError.invalidFormat("\(label) code chunk has no supported signature")
                    }
                    pageSize = directory.pageSize
                    pageSizes[firstChunk] = pageSize
                }
                index += 1
                while index < writes.count {
                    let previous = writes[index - 1]
                    let next = writes[index]
                    if next.address == previous.address {
                        guard next.word == previous.word else {
                            throw PatcherError.invalidFormat("conflicting \(label) rewrites")
                        }
                        index += 1
                        continue
                    }
                    guard start / UInt64(pageSize) == next.address / UInt64(pageSize),
                          let range = try? chunks.fileRange(
                            of: .init(vma: start, length: Int(next.address + 4 - start)),
                          ),
                          range.chunkURL == firstChunk
                    else { break }
                    index += 1
                }

                let length = Int(writes[index - 1].address + 4 - start)
                let before = try chunks.bytesAtVMA(start, length: length)
                var after = before
                var changed = 0
                for write in writes[first ..< index] {
                    let offset = Int(write.address - start)
                    let replacement = ARM64.encodeU32(write.word)
                    if after.subdata(in: offset ..< offset + 4) != replacement { changed += 1 }
                    after.replaceSubrange(offset ..< offset + 4, with: replacement)
                }
                if before != after {
                    try chunks.write(at: start, after)
                    groups += 1
                    if !skipsUnplannable {
                        log("  0x\(String(start, radix: 16)): \(changed) instruction(s) [\(patchID)]")
                    }
                }
            }
            try finish(chunks, selected)
            let attestation = try DyldSharedCacheCodeSignature.reattestRecordedWrites(in: chunks, log: log)
            guard attestation.isFullyAttested else {
                throw PatcherError.invalidFormat(
                    "\(label) re-attestation skipped \(attestation.skipped.count) pages",
                )
            }
            onUndo(chunks.takeUndoLog()!)
            log("  [+] \(label): \(writes.count) instruction rewrites in \(groups) page run(s)")
        } catch {
            var undo = chunks.takeUndoLog()!
            if !undo.records.isEmpty {
                undo.stamp(patchID: patchID)
                let spans = try undo.restore(patchIDs: undo.patchIDs, in: directory, log: log)
                _ = try DyldSharedCacheCodeSignature.reattest(
                    in: chunks,
                    modifiedSpans: spans,
                    log: log,
                )
            }
            throw error
        }
    }

    static func refreshCoreCryptoIntegrity(
        at address: UInt64,
        in chunks: DyldSharedCacheChunkSet,
        log: (String) -> Void,
    ) throws {
        let prefix = try chunks.bytesAtVMA(address, length: 32)
        guard prefix.loadLE(UInt32.self, at: 0) == 0xFEED_FACF else {
            throw PatcherError.invalidFormat("cached corecrypto has no Mach-O header")
        }
        let commandBytes = Int(prefix.loadLE(UInt32.self, at: 20))
        guard commandBytes <= 1_048_576 else {
            throw PatcherError.invalidFormat("oversized cached corecrypto commands")
        }
        let header = try chunks.bytesAtVMA(address, length: 32 + commandBytes)
        let sections = MachOParser.parseSections(from: header)
        guard let text = sections["__TEXT,__text"], text.size > 0,
              let expected = sections["__TEXT,__fips_hmacs"], expected.size == SHA256.byteCount,
              let textLength = Int(exactly: text.size)
        else {
            throw PatcherError.invalidFormat("cached corecrypto FIPS sections are missing or malformed")
        }
        let code = try chunks.bytesAtVMA(text.address, length: textLength)
        let key = SymmetricKey(data: Data(repeating: 0, count: SHA256.byteCount))
        let digest = Data(HMAC<SHA256>.authenticationCode(for: code, using: key))
        let stored = try chunks.bytesAtVMA(expected.address, length: SHA256.byteCount)
        guard stored != digest else {
            log("  [=] X1 bootstrap cache: corecrypto FIPS HMAC already matches")
            return
        }
        try chunks.write(at: expected.address, digest)
        log("  [+] X1 bootstrap cache: refreshed corecrypto FIPS HMAC")
    }

    static func planImage(
        at address: UInt64,
        in chunks: DyldSharedCacheChunkSet,
        identifier: String = FirmwareGuestSystemPatchSet.arm64eX1CacheBootstrap,
        decoder: CustomFirmwareArm64eX1.Decoder = .init(),
    ) throws -> CustomFirmwareArm64eX1.Result {
        let prefix = try chunks.bytesAtVMA(address, length: 32)
        guard prefix.loadLE(UInt32.self, at: 0) == 0xFEED_FACF else {
            throw PatcherError.invalidFormat("cache image has no Mach-O header")
        }
        guard prefix.loadLE(UInt32.self, at: 8) & 0x00FF_FFFF == 12 else {
            return .init(records: [], unvisitedCandidates: 0)
        }
        let commandBytes = Int(prefix.loadLE(UInt32.self, at: 20))
        guard commandBytes <= 1_048_576 else {
            throw PatcherError.invalidFormat("oversized cache image commands")
        }
        let header = try chunks.bytesAtVMA(address, length: 32 + commandBytes)
        let segments = MachOParser.parseSegments(from: header)
        let allSections = Array(MachOParser.parseSections(from: header).values)
        let sections = allSections.filter {
            ($0.sectionName == "__text" || $0.flags & 0x8000_0400 != 0) && $0.size > 0
        }
        if sections.isEmpty { return .init(records: [], unvisitedCandidates: 0) }
        guard let text = segments.first(where: { $0.name == "__TEXT" }),
              let linkedit = segments.first(where: { $0.name == "__LINKEDIT" })
        else {
            throw PatcherError.invalidFormat("X1 cached text/linkedit missing")
        }

        func metadata(_ offset: UInt64, _ length: Int) throws -> Data {
            guard offset >= linkedit.fileOffset,
                  UInt64(length) <= linkedit.fileSize,
                  offset - linkedit.fileOffset <= linkedit.fileSize - UInt64(length)
            else { throw PatcherError.invalidFormat("cached X1 metadata outside linkedit") }
            return try chunks.bytesAtVMA(
                linkedit.vmAddr + offset - linkedit.fileOffset,
                length: length,
            )
        }

        var position = 32
        var seeds: [Int] = []
        var excluded: [Range<Int>] = []
        for _ in 0 ..< header.loadLE(UInt32.self, at: 16) {
            guard position + 8 <= header.count else {
                throw PatcherError.invalidFormat("truncated cache commands")
            }
            let command = header.loadLE(UInt32.self, at: position)
            let size = Int(header.loadLE(UInt32.self, at: position + 4))
            guard size >= 8, size <= header.count - position else {
                throw PatcherError.invalidFormat("invalid cache command")
            }
            if command == 0x26 || command == 0x29 {
                guard size >= 16 else {
                    throw PatcherError.invalidFormat("short cache linkedit command")
                }
                let offset = UInt64(header.loadLE(UInt32.self, at: position + 8))
                let length = Int(header.loadLE(UInt32.self, at: position + 12))
                if length > 0 {
                    let bytes = try metadata(offset, length)
                    if command == 0x26 {
                        var cursor = 0
                        var current = text.vmAddr
                        while cursor < bytes.count {
                            var delta: UInt64 = 0
                            var shift = 0
                            while true {
                                guard cursor < bytes.count, shift < 63 else {
                                    throw PatcherError.invalidFormat("invalid cached function starts")
                                }
                                let byte = bytes[cursor]
                                cursor += 1
                                delta |= UInt64(byte & 0x7F) << shift
                                if byte & 0x80 == 0 { break }
                                shift += 7
                            }
                            if delta == 0 { break }
                            let (next, overflow) = current.addingReportingOverflow(delta)
                            guard !overflow, let entry = Int(exactly: next) else {
                                throw PatcherError.invalidFormat("cached function address overflow")
                            }
                            current = next
                            seeds.append(entry)
                        }
                    } else {
                        guard bytes.count % 8 == 0 else {
                            throw PatcherError.invalidFormat("invalid cached data-in-code")
                        }
                        for entry in stride(from: 0, to: bytes.count, by: 8) {
                            let offset = UInt64(bytes.loadLE(UInt32.self, at: entry))
                            let length = Int(bytes.loadLE(UInt16.self, at: entry + 4))
                            guard let segment = segments.first(where: {
                                offset >= $0.fileOffset && offset - $0.fileOffset < $0.fileSize
                            }) else {
                                throw PatcherError.invalidFormat("cached data-in-code offset unmapped")
                            }
                            let start = Int(segment.vmAddr + offset - segment.fileOffset)
                            excluded.append(start ..< start + length)
                        }
                    }
                }
            }
            position += size
        }
        guard !seeds.isEmpty else {
            throw PatcherError.invalidFormat("X1 cache image has no function starts")
        }
        seeds += try CustomFirmwareArm64eX1.exceptionEntries(
            sections: allSections,
            imageBase: text.vmAddr,
            readMemory: { try chunks.bytesAtVMA($0, length: $1) },
        ).map { address in
            guard let value = Int(exactly: address) else {
                throw PatcherError.invalidFormat("X1 exception landing address overflow")
            }
            return value
        }
        let ranges = try sections.map {
            (address: Int($0.address), data: try chunks.bytesAtVMA($0.address, length: Int($0.size)))
        }
        var pointerCaches: [URL: DyldCache] = [:]
        var mainHeader: DyldCacheHeader?
        return try CustomFirmwareArm64eX1.planCode(
            ranges: ranges,
            seeds: seeds,
            excluded: excluded,
            identifier: identifier,
            readMemory: { address, length in
                return try chunks.bytesAtVMA(UInt64(address), length: length)
            },
            authenticatedPointer: { address, diversity in
                let range = try chunks.fileRange(of: .init(vma: address, length: 8))
                let header: DyldCacheHeader
                if let loaded = mainHeader {
                    header = loaded
                } else {
                    header = try DyldCache(url: chunks.mainCacheURL).header
                    mainHeader = header
                }
                let cache: DyldCache
                if let known = pointerCaches[range.chunkURL] {
                    cache = known
                } else {
                    cache = try DyldCache(subcacheUrl: range.chunkURL, mainCacheHeader: header)
                    pointerCaches[range.chunkURL] = cache
                }
                guard let mapping = cache.mappingAndSlideInfos?.first(where: {
                    address >= $0.address && address - $0.address < $0.size
                }), mapping.slideInfoVersion(in: cache) == .v5
                else { return nil }
                let word = try chunks.bytesAtVMA(address, length: 8).loadLE(UInt64.self, at: 0)
                return try authenticatedTargetV5(
                    word: word,
                    base: header.sharedRegionStart,
                    diversity: diversity,
                )
            },
            decoder: decoder,
        )
    }

    static func authenticatedTargetV5(
        word: UInt64,
        base: UInt64,
        diversity: UInt16,
    ) throws -> UInt64? {
        guard word >> 63 == 1,
              (word >> 34) & 0xFFFF == UInt64(diversity),
              (word >> 50) & 3 == 0
        else { return nil }
        let (target, overflow) = base.addingReportingOverflow(word & ((1 << 34) - 1))
        guard !overflow else {
            throw PatcherError.invalidFormat("X1 authenticated pointer overflow")
        }
        return target
    }
}
