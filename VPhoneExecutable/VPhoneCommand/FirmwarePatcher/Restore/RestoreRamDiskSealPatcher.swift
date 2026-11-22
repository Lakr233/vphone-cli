// iOS 27 sha3_256_4k root-hash compatibility for the cloudOS restore ramdisk.

import CryptoKit
import Foundation
import VPhonePatchKit

// MARK: - Shared State

final class RestoreRamDiskSealPatchContext {
    var originalCDHash: Data?
    var patchedCDHash: Data?
}

// MARK: - Restore Ramdisk

final class RestoreRamDiskSealPatcher: BufferedPatcher {
    static let patchIdentifier = "restoreramdisk-boot-apfs_sha3_hash"
    static let sealVolumePath = "System/Library/Filesystems/apfs.fs/apfs_sealvolume"
    static let sha256Type: UInt32 = 1
    static let sha3_256_4KType: UInt32 = 0x106

    /// isys payload: hash type at +8, digest length at +12.
    static func systemVolumeHashType(in restoreDir: URL) throws -> UInt32 {
        let path = try FirmwarePipeline.manifestComponentPath("SystemVolume", in: restoreDir)
        let url = restoreDir.appending(path: path)
        let (payload, im4p) = try IM4PHandler.load(contentsOf: url)
        guard im4p?.fourcc == "isys", payload.count >= 48 else {
            throw PatcherError.invalidFormat("SystemVolume root hash is not an isys IM4P with a 32-byte digest")
        }
        let hashType = payload.loadLE(UInt32.self, at: 8)
        let digestLength = payload.loadLE(UInt32.self, at: 12)
        guard digestLength == 32,
              hashType == sha256Type || hashType == sha3_256_4KType
        else {
            throw PatcherError.invalidFormat(
                "SystemVolume root hash has unsupported hash type 0x\(String(hashType, radix: 16)) "
                    + "or digest length \(digestLength)",
            )
        }
        return hashType
    }

    let component = VPhoneFirmwareComponent.restoreRamDisk.rawValue
    let verbose: Bool
    var gate: VPhonePatchGate = .unrestricted

    private let originalData: Data
    private let context: RestoreRamDiskSealPatchContext
    private var resultData: Data?
    private var records: [PatchRecord]?

    init(data: Data, context: RestoreRamDiskSealPatchContext, verbose: Bool = true) {
        originalData = data.startIndex == 0 ? data : Data(data)
        self.context = context
        self.verbose = verbose
    }

    func findAll() throws -> [PatchRecord] {
        if let records { return records }
        guard gateAllows(Self.patchIdentifier + ".hash_type") else {
            records = []
            return []
        }

        let temporary = FileManager.default.temporaryDirectory
            .appendingPathComponent("vphone-seal-\(UUID().uuidString)", isDirectory: true)
        let image = temporary.appendingPathComponent("RestoreRamDisk.dmg")
        let mount = temporary.appendingPathComponent("mount", isDirectory: true)
        try FileManager.default.createDirectory(at: mount, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: temporary) }
        try originalData.write(to: image)

        let attachment = try Self.attach(image: image, at: mount)
        var attached = true
        defer {
            if attached {
                try? Self.detach(attachment.device)
            }
        }

        let executable = attachment.mount.appendingPathComponent(Self.sealVolumePath)
        guard FileManager.default.fileExists(atPath: executable.path) else {
            throw PatcherError.fileNotFound("\(component): \(Self.sealVolumePath)")
        }

        var binary = try Data(contentsOfFileToRewrite: executable)
        let fieldOffset = try Self.locateHashTypeField(in: binary)
        let oldValue = binary.loadLE(UInt32.self, at: fieldOffset)
        guard oldValue == Self.sha256Type else {
            throw PatcherError.patchVerificationFailed(
                "apfs_sealvolume hash type at 0x\(String(fieldOffset, radix: 16)) is "
                    + "0x\(String(oldValue, radix: 16)), expected sha256 (1)",
            )
        }

        let originalCDHash = try Self.primaryCDHash(of: binary)
        let replacement = Self.littleEndian(Self.sha3_256_4KType)
        binary.replaceSubrange(fieldOffset ..< fieldOffset + 4, with: replacement)
        let rehashes = try CustomFirmwareMachOCodeSignature.reattest(
            &binary,
            modifiedOffsets: [fieldOffset],
        )
        guard !rehashes.isEmpty else {
            throw PatcherError.patchVerificationFailed(
                "apfs_sealvolume hash-type field is outside every SHA-256 CodeDirectory page",
            )
        }
        let patchedCDHash = try Self.primaryCDHash(of: binary)
        guard patchedCDHash != originalCDHash else {
            throw PatcherError.patchVerificationFailed("apfs_sealvolume cdhash did not change")
        }

        // Preserve the inode and mode inside the restore ramdisk.
        let handle = try FileHandle(forWritingTo: executable)
        try handle.seek(toOffset: 0)
        try handle.write(contentsOf: binary)
        try handle.truncate(atOffset: UInt64(binary.count))
        try handle.close()

        try Self.detach(attachment.device)
        attached = false
        resultData = try Data(contentsOf: image, options: .mappedIfSafe)
        context.originalCDHash = originalCDHash
        context.patchedCDHash = patchedCDHash

        let record = PatchRecord(
            patchID: Self.patchIdentifier + ".hash_type",
            component: component,
            fileOffset: fieldOffset,
            originalBytes: Self.littleEndian(Self.sha256Type),
            patchedBytes: replacement,
            beforeDisasm: "hash type 1 (sha256)",
            afterDisasm: "hash type 0x106 (sha3_256_4k)",
            description: "Use iOS 27's sha3_256_4k algorithm for the APFS root hash",
        )
        records = [record]

        if verbose {
            print("  apfs_sealvolume cdhash: \(originalCDHash.hex) → \(patchedCDHash.hex)")
        }
        return [record]
    }

    @discardableResult
    func apply() throws -> Int {
        try findAll().count
    }

    var patchedData: Data {
        resultData ?? originalData
    }

    // MARK: Mach-O Discovery

    static func locateHashTypeField(in binary: Data) throws -> Int {
        let sections = MachOParser.parseSections(from: binary)
        let segments = MachOParser.parseSegments(from: binary)
        guard let text = sections["__TEXT,__text"],
              let cstrings = sections["__TEXT,__cstring"],
              let constants = sections["__DATA_CONST,__const"]
        else {
            throw PatcherError.invalidFormat("apfs_sealvolume is missing text, cstring, or data-const sections")
        }

        try requireCString("sha256", in: binary, section: cstrings)
        try requireCString("sha3_256_4k", in: binary, section: cstrings)
        let optionsOffset = try uniqueCStringOffset(
            "cynfhvds:o:pH:F:t:TM:R:V:I:D:PU:u:SfrE:XxLam",
            in: binary,
            section: cstrings,
        )
        let optionsVMA = cstrings.address + UInt64(optionsOffset - Int(cstrings.fileOffset))
        let optionReferences = findADRPADDReferences(
            to: optionsVMA,
            in: binary,
            text: text,
        )
        guard optionReferences.count == 1, let optionsReference = optionReferences.first else {
            throw PatcherError.patchVerificationFailed(
                "apfs_sealvolume getopt anchor has \(optionReferences.count) ADRP+ADD references, expected one",
            )
        }

        let disassembler = ARM64Disassembler()
        let floor = max(Int(text.fileOffset), optionsReference - 0x180)
        var candidates: [Int] = []
        var offset = floor - (floor % 4)
        while offset + 32 <= optionsReference {
            let address = text.address + UInt64(offset - Int(text.fileOffset))
            let instructions = disassembler.disassemble(in: binary, at: offset, count: 8, address: address)
            if let targetVMA = copiedTemplateTarget(instructions),
               targetVMA >= constants.address,
               targetVMA + 96 <= constants.address + constants.size,
               let targetOffset = MachOParser.vaToFileOffset(targetVMA, segments: segments),
               targetOffset + 28 <= binary.count
            {
                let value = binary.loadLE(UInt32.self, at: targetOffset + 24)
                if value == sha256Type || value == sha3_256_4KType {
                    candidates.append(targetOffset + 24)
                }
            }
            offset += 4
        }

        let unique = Array(Set(candidates)).sorted()
        guard unique.count == 1, let field = unique.first else {
            throw PatcherError.patchVerificationFailed(
                "apfs_sealvolume options template has \(unique.count) hash-type candidates, expected one",
            )
        }
        return field
    }

    private static func copiedTemplateTarget(_ instructions: [ARM64Instruction]) -> UInt64? {
        guard instructions.count == 8,
              instructions[0].mnemonic == "adrp",
              instructions[1].mnemonic == "add",
              let adrp = instructions[0].detail?.operands,
              adrp.count == 2,
              adrp[0].type == .register, adrp[0].reg == .x(8),
              adrp[1].type == .immediate, adrp[1].imm >= 0,
              let add = instructions[1].detail?.operands,
              add.count == 3,
              add[0].type == .register, add[0].reg == .x(8),
              add[1].type == .register, add[1].reg == .x(8),
              add[2].type == .immediate, add[2].imm >= 0
        else { return nil }

        for pair in 0 ..< 3 {
            let load = instructions[2 + pair * 2]
            let store = instructions[3 + pair * 2]
            guard load.mnemonic == "ldp",
                  store.mnemonic == "stp",
                  load.detail?.operands.last?.type == .memory,
                  load.detail?.operands.last?.mem.base == .x(8),
                  store.detail?.operands.last?.type == .memory,
                  store.detail?.operands.last?.mem.base == .x(20)
            else { return nil }
        }
        return UInt64(adrp[1].imm) + UInt64(add[2].imm)
    }

    private static func findADRPADDReferences(
        to targetVMA: UInt64,
        in binary: Data,
        text: MachOSectionInfo,
    ) -> [Int] {
        guard let start = Int(exactly: text.fileOffset),
              let textSize = Int(exactly: text.size),
              start < binary.count else { return [] }
        let size = min(textSize, binary.count - start)
        guard size > 0 else { return [] }
        let instructions = ARM64Disassembler().disassemble(
            Data(binary[start ..< start + size]),
            at: text.address,
        )
        var pending: [ARM64Register: (index: Int, page: UInt64)] = [:]
        var references: [Int] = []
        for (index, instruction) in instructions.enumerated() {
            guard let operands = instruction.detail?.operands else { continue }
            if instruction.mnemonic == "adrp",
               operands.count == 2,
               operands[0].type == .register,
               operands[1].type == .immediate,
               operands[1].imm >= 0
            {
                pending[operands[0].reg] = (index, UInt64(operands[1].imm))
                continue
            }
            guard instruction.mnemonic == "add",
                  operands.count == 3,
                  operands[0].type == .register,
                  operands[1].type == .register,
                  operands[0].reg == operands[1].reg,
                  operands[2].type == .immediate,
                  operands[2].imm >= 0,
                  let base = pending[operands[1].reg],
                  index - base.index <= 8,
                  base.page + UInt64(operands[2].imm) == targetVMA
            else { continue }
            references.append(start + Int(instruction.address - text.address) - (index - base.index) * 4)
        }
        return references
    }

    private static func requireCString(
        _ string: String,
        in data: Data,
        section: MachOSectionInfo,
    ) throws {
        _ = try uniqueCStringOffset(string, in: data, section: section)
    }

    private static func uniqueCStringOffset(
        _ string: String,
        in data: Data,
        section: MachOSectionInfo,
    ) throws -> Int {
        var pattern = Data(string.utf8)
        pattern.append(0)
        guard let lower = Int(exactly: section.fileOffset),
              let size = Int(exactly: section.size),
              lower <= data.count, size <= data.count - lower else {
            throw PatcherError.invalidFormat("apfs_sealvolume cstring section lies outside the file")
        }
        let upper = lower + size
        var matches: [Int] = []
        var cursor = lower
        while cursor + pattern.count <= upper,
              let range = data.range(of: pattern, in: cursor ..< upper)
        {
            matches.append(range.lowerBound)
            cursor = range.lowerBound + 1
        }
        guard matches.count == 1, let match = matches.first else {
            throw PatcherError.patchVerificationFailed(
                "apfs_sealvolume cstring '\(string)' occurs \(matches.count) times, expected one",
            )
        }
        return match
    }

    static func primaryCDHash(of binary: Data) throws -> Data {
        guard let directories = CustomFirmwareMachOCodeSignature.codeDirectories(in: binary),
              let directory = directories.first(where: {
                  $0.slotType == 0 && $0.hashType == CustomFirmwareMachOCodeSignature.hashTypeSHA256
              })
        else {
            throw PatcherError.invalidFormat("apfs_sealvolume has no primary SHA-256 CodeDirectory")
        }
        return Data(SHA256.hash(data: binary[directory.offset ..< directory.offset + directory.length])).prefix(20)
    }

    private static func littleEndian(_ value: UInt32) -> Data {
        withUnsafeBytes(of: value.littleEndian) { Data($0) }
    }

    // MARK: Disk Image I/O

    private static func attach(image: URL, at mount: URL) throws -> (device: String, mount: URL) {
        let output = try run(
            "/usr/bin/hdiutil",
            ["attach", "-plist", "-readwrite", "-owners", "off", "-nobrowse", "-mountpoint", mount.path, image.path],
        )
        guard let plist = try PropertyListSerialization.propertyList(from: output, format: nil) as? [String: Any],
              let entities = plist["system-entities"] as? [[String: Any]],
              let root = entities.first?["dev-entry"] as? String,
              let mountedPath = entities.compactMap({ $0["mount-point"] as? String }).first
        else {
            throw PatcherError.invalidFormat("hdiutil did not report the restore ramdisk mount")
        }
        return (root, URL(fileURLWithPath: mountedPath, isDirectory: true))
    }

    private static func detach(_ device: String) throws {
        _ = try run("/usr/bin/hdiutil", ["detach", device])
    }

    private static func run(_ executable: String, _ arguments: [String]) throws -> Data {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        let standardOutput = Pipe()
        let standardError = Pipe()
        process.standardOutput = standardOutput
        process.standardError = standardError
        try process.run()
        process.waitUntilExit()
        let output = standardOutput.fileHandleForReading.readDataToEndOfFile()
        let error = standardError.fileHandleForReading.readDataToEndOfFile()
        guard process.terminationStatus == 0 else {
            let message = String(data: error, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            throw PatcherError.patchVerificationFailed(
                "\((executable as NSString).lastPathComponent) exited \(process.terminationStatus): \(message)",
            )
        }
        return output
    }
}

// MARK: - Restore Trust Cache

final class RestoreTrustCacheSealPatcher: BufferedPatcher {
    static let entrySize = 22
    static let headerSize = 24

    let component = VPhoneFirmwareComponent.restoreTrustCache.rawValue
    let verbose: Bool
    var gate: VPhonePatchGate = .unrestricted

    private let originalData: Data
    private let context: RestoreRamDiskSealPatchContext
    private var resultData: Data?
    private var records: [PatchRecord]?

    init(data: Data, context: RestoreRamDiskSealPatchContext, verbose: Bool = true) {
        originalData = data.startIndex == 0 ? data : Data(data)
        self.context = context
        self.verbose = verbose
    }

    func findAll() throws -> [PatchRecord] {
        if let records { return records }
        let patchID = RestoreRamDiskSealPatcher.patchIdentifier + ".trustcache"
        guard gateAllows(patchID) else {
            records = []
            return []
        }
        guard let oldHash = context.originalCDHash, let newHash = context.patchedCDHash else {
            throw PatcherError.patchVerificationFailed(
                "RestoreTrustCache ran before the RestoreRamDisk cdhash was available",
            )
        }
        let replaced = try Self.replacingCDHash(in: originalData, from: oldHash, to: newHash)
        resultData = replaced.data
        let changed = replaced.changedRange
        let record = PatchRecord(
            patchID: patchID,
            component: component,
            fileOffset: changed.lowerBound,
            originalBytes: Data(originalData[changed]),
            patchedBytes: Data(replaced.data[changed]),
            beforeDisasm: oldHash.hex,
            afterDisasm: newHash.hex,
            description: "Trust the re-attested apfs_sealvolume used for iOS 27 sealing",
        )
        records = [record]
        if verbose {
            print("  RestoreTrustCache cdhash: \(oldHash.hex) → \(newHash.hex)")
        }
        return [record]
    }

    @discardableResult
    func apply() throws -> Int {
        try findAll().count
    }

    var patchedData: Data {
        resultData ?? originalData
    }

    static func replacingCDHash(
        in data: Data,
        from oldHash: Data,
        to newHash: Data,
    ) throws -> (data: Data, changedRange: Range<Int>) {
        guard oldHash.count == 20, newHash.count == 20 else {
            throw PatcherError.invalidFormat("trust-cache cdhashes must be 20 bytes")
        }
        guard oldHash != newHash else {
            throw PatcherError.invalidFormat("trust-cache replacement cdhash is unchanged")
        }
        guard data.count >= headerSize, data.loadLE(UInt32.self, at: 0) == 1 else {
            throw PatcherError.invalidFormat("RestoreTrustCache is not a v1 trust cache")
        }
        let count = Int(data.loadLE(UInt32.self, at: 20))
        guard headerSize + count * entrySize == data.count else {
            throw PatcherError.invalidFormat(
                "RestoreTrustCache size \(data.count) does not match its \(count) v1 entries",
            )
        }

        var entries: [Data] = []
        var matchCount = 0
        for index in 0 ..< count {
            let offset = headerSize + index * entrySize
            var entry = Data(data[offset ..< offset + entrySize])
            if entry.prefix(20) == oldHash {
                matchCount += 1
                entry.replaceSubrange(0 ..< 20, with: newHash)
            }
            entries.append(entry)
        }
        guard matchCount == 1 else {
            throw PatcherError.patchVerificationFailed(
                "apfs_sealvolume cdhash occurs \(matchCount) times in RestoreTrustCache, expected one",
            )
        }
        entries.sort { $0.lexicographicallyPrecedes($1) }

        var rebuilt = Data(data.prefix(headerSize))
        for entry in entries { rebuilt.append(entry) }
        guard let firstDifference = data.indices.first(where: { data[$0] != rebuilt[$0] }),
              let lastDifference = data.indices.last(where: { data[$0] != rebuilt[$0] })
        else {
            throw PatcherError.patchVerificationFailed("trust-cache replacement changed no bytes")
        }
        return (rebuilt, firstDifference ..< lastDifference + 1)
    }
}
