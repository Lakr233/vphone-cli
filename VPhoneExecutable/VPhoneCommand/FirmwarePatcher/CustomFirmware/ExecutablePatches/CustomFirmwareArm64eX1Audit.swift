import Darwin
import Foundation
import VPhoneCoreKit
import VPhonePatchKit

/// Read-only coverage audit of standalone userland images. Names and suffixes
/// do not decide applicability: discover Mach-O files, then run the production
/// lowering planner and signature-coverage checks in private memory.
public enum CustomFirmwareArm64eX1Audit {
    public enum State: String, Codable, Sendable {
        case noLoweringNeeded, needsLowering, incomplete, failed
    }

    public struct Image: Codable, Sendable {
        public let path: String
        public let bytes: Int
        public let declarations: [String]
        public let state: State
        public let instructions: Int?
        public let codeSlots: Int?
        public let unvisitedCandidates: Int?
        public let unvisitedExamples: [Int]?
        public let error: String?
    }

    public struct Failure: Codable, Sendable {
        public let path: String
        public let error: String
    }

    public struct Report: Codable, Sendable {
        public let root: String
        public var examinedFiles = 0
        public var skippedBackups = 0
        public var images: [Image] = []
        public var failures: [Failure] = []

        public var needsAttention: Bool {
            !failures.isEmpty || images.contains { $0.state != .noLoweringNeeded }
        }
    }

    public static func scan(root: URL, includeExecutables: Bool = false) throws -> Report {
        let system = try VPhoneConfinedDirectory(root: root.path)
        var report = try Report(root: system.path)
        let types: Set<UInt32> = includeExecutables ? [2, 6, 7, 8] : [6, 8]
        let declarations = FirmwarePatchSetCatalog.allDeclarations.filter { $0.identifier.contains("arm64e_x1") }

        func inspect(_ directory: VPhoneConfinedDirectory, name: String, path: String) throws {
            let file = try directory.openRegularFile(name)
            guard file.size >= 32 else { return }
            report.examinedFiles += 1
            var bytes = [UInt8](repeating: 0, count: 32)
            var count: Int
            repeat { count = pread(file.descriptor, &bytes, bytes.count, 0) } while count < 0 && errno == EINTR
            guard count >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
            let header = Data(bytes.prefix(count))
            guard header.count == 32 else { throw PatcherError.invalidFormat("truncated Mach-O probe") }
            let magic = header.loadLE(UInt32.self, at: 0)
            if magic == 0xFEED_FACF {
                guard isX1(header, at: 0), types.contains(header.loadLE(UInt32.self, at: 12)) else { return }
            } else if magic != 0xBEBA_FECA, magic != 0xBFBA_FECA {
                return
            }
            // pread leaves the verified descriptor at its start. Do not reopen
            // the path or follow a link between discovery and analysis.
            var data = try FileHandle(fileDescriptor: file.descriptor, closeOnDealloc: false).readToEnd() ?? Data()
            let ids = declarations.compactMap { declaration -> String? in
                switch declaration.target {
                case let .guestExecutable(target), let .guestFile(target):
                    target == "/" + path ? declaration.identifier : nil
                default: nil
                }
            }.sorted()
            let size = data.count
            do {
                guard try containsX1(data, types: types) else { return }
                let result = try CustomFirmwareArm64eX1.lowerAndReattest(&data, identifier: "audit")
                let state: State = result.result.unvisitedCandidates > 0 ? .incomplete
                    : result.result.records.isEmpty ? .noLoweringNeeded : .needsLowering
                report.images.append(Image(
                    path: path, bytes: size, declarations: ids, state: state,
                    instructions: result.result.records.count, codeSlots: result.slots.count,
                    unvisitedCandidates: result.result.unvisitedCandidates,
                    unvisitedExamples: result.result.unvisitedExamples, error: nil,
                ))
            } catch {
                report.images.append(Image(
                    path: path, bytes: size, declarations: ids, state: .failed,
                    instructions: nil, codeSlots: nil, unvisitedCandidates: nil, unvisitedExamples: nil,
                    error: String(describing: error),
                ))
            }
        }

        func visit(_ directory: VPhoneConfinedDirectory, prefix: String) {
            do {
                for name in try directory.entries().sorted() {
                    let path = prefix + name
                    autoreleasepool {
                        // A pristine backup is not a runtime image. A backup
                        // directory must also be skipped before descending.
                        guard !name.hasSuffix(".bak") else { report.skippedBackups += 1; return }
                        do {
                            guard let status = try directory.status(name) else { return }
                            switch status.st_mode & S_IFMT {
                            case S_IFDIR: visit(try directory.directory(name), prefix: path + "/")
                            case S_IFREG where status.st_size >= 32: try inspect(directory, name: name, path: path)
                            default: break // No symlinks, devices, sockets or FIFOs.
                            }
                        } catch {
                            report.failures.append(Failure(path: path, error: String(describing: error)))
                        }
                    }
                }
            } catch {
                report.failures.append(Failure(path: prefix, error: String(describing: error)))
            }
        }
        visit(system, prefix: "")
        report.images.sort { $0.path < $1.path }
        return report
    }

    private static func isX1(_ data: Data, at offset: Int) -> Bool {
        data.count >= 32 && offset >= 0 && offset <= data.count - 32
            && data.loadLE(UInt32.self, at: offset) == 0xFEED_FACF
            && data.loadLE(UInt32.self, at: offset + 4) == 0x0100_000C
            && data.loadLE(UInt32.self, at: offset + 8) & 0x00FF_FFFF == 12
    }

    /// Cheap architecture/type selection only. The production converter still
    /// validates universal ranges, overlaps and architecture/header agreement.
    private static func containsX1(_ data: Data, types: Set<UInt32>) throws -> Bool {
        guard data.count >= 32 else { throw PatcherError.invalidFormat("truncated Mach-O") }
        let magic = data.loadLE(UInt32.self, at: 0)
        if magic == 0xFEED_FACF {
            guard isX1(data, at: 0), types.contains(data.loadLE(UInt32.self, at: 12)) else { return false }
            try validateLoadCommands(data)
            return true
        }
        let wide = magic == 0xBFBA_FECA
        let stride = wide ? 32 : 20
        let count = Int(UInt32(bigEndian: data.loadLE(UInt32.self, at: 4)))
        // CAFEBABE also opens Java class files, and a damaged non-X1 container
        // is outside this audit. Only an X1 entry makes a bad table an error.
        let readable = min(count, (data.count - 8) / stride)
        let declaresX1 = (0..<readable).contains { index in
            let entry = 8 + index * stride
            return UInt32(bigEndian: data.loadLE(UInt32.self, at: entry)) == 0x0100_000C
                && UInt32(bigEndian: data.loadLE(UInt32.self, at: entry + 4)) & 0x00FF_FFFF == 12
        }
        guard declaresX1 else { return false }
        guard count == readable else {
            throw PatcherError.invalidFormat("truncated universal architecture table")
        }
        var found = false
        for index in 0..<count {
            let entry = 8 + index * stride
            let cpu = UInt32(bigEndian: data.loadLE(UInt32.self, at: entry))
            let subtype = UInt32(bigEndian: data.loadLE(UInt32.self, at: entry + 4))
            guard cpu == 0x0100_000C, subtype & 0x00FF_FFFF == 12 else { continue }
            let raw = wide ? UInt64(bigEndian: data.loadLE(UInt64.self, at: entry + 8))
                : UInt64(UInt32(bigEndian: data.loadLE(UInt32.self, at: entry + 8)))
            let size = wide ? UInt64(bigEndian: data.loadLE(UInt64.self, at: entry + 16))
                : UInt64(UInt32(bigEndian: data.loadLE(UInt32.self, at: entry + 12)))
            guard let offset = Int(exactly: raw), let length = Int(exactly: size),
                  offset >= 8 + count * stride, length >= 32, offset <= data.count,
                  length <= data.count - offset, isX1(data, at: offset) else {
                throw PatcherError.invalidFormat("invalid X1 universal slice")
            }
            if types.contains(data.loadLE(UInt32.self, at: offset + 12)) {
                try validateLoadCommands(data.subdata(in: offset..<offset + length))
                found = true
            }
        }
        return found
    }

    /// MachOParser deliberately tolerates partial tables for binary research.
    /// An audit must not mistake that partial result for an image with no code.
    private static func validateLoadCommands(_ data: Data) throws {
        let count = Int(data.loadLE(UInt32.self, at: 16))
        let size = Int(data.loadLE(UInt32.self, at: 20))
        guard size <= data.count - 32, count <= size / 8 else {
            throw PatcherError.invalidFormat("truncated X1 load-command table")
        }
        let end = 32 + size
        var offset = 32
        for _ in 0..<count {
            guard offset <= end - 8 else { throw PatcherError.invalidFormat("truncated X1 load command") }
            let command = data.loadLE(UInt32.self, at: offset)
            let length = Int(data.loadLE(UInt32.self, at: offset + 4))
            guard length >= 8, length.isMultiple(of: 8), length <= end - offset else {
                throw PatcherError.invalidFormat("invalid X1 load-command size")
            }
            if command == 0x19 { // LC_SEGMENT_64
                guard length >= 72, Int(data.loadLE(UInt32.self, at: offset + 64)) <= (length - 72) / 80 else {
                    throw PatcherError.invalidFormat("truncated X1 segment sections")
                }
            }
            offset += length
        }
        guard offset == end else { throw PatcherError.invalidFormat("inconsistent X1 load-command table size") }
    }
}
