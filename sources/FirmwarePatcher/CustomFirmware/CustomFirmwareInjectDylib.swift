// CustomFirmwareInjectDylib.swift — LC_LOAD_DYLIB / LC_LOAD_WEAK_DYLIB insertion.
//
// Replaces the `insert_dylib` binary built from `scripts/repos/insert_dylib`,
// whose only caller is the launchdhook injection in `cfw_install_jb.sh` and
// `cfw_install_exp.sh`:
//
//     cfw.py inject-dylib "$TEMP_DIR/launchd" "/b"
//       -> insert_dylib --weak --inplace --all-yes /b <launchd>
//
// This is a deliberate behaviour-for-behaviour port, because byte equality with
// the C tool is the only independent check available for it. Two things differ
// on purpose, both in the safe direction, both marked below:
//
//   1. `insert_dylib --all-yes` answers "y" to "It doesn't seem like there is
//      enough empty space. Continue anyway?" and then writes the load command
//      over whatever follows the load-command region — normally the first bytes
//      of __text. That silently corrupts the binary. We throw instead, unless
//      the caller opts in.
//   2. `insert_dylib` supports big-endian and 32-bit Mach-Os. Nothing in this
//      pipeline is either, so they are rejected rather than half-supported.
//
// Inserting the command does not move anything: it is written into the zero
// padding between the end of the load commands and the first section, and only
// `ncmds` / `sizeofcmds` in the header change. What *does* move is the code
// signature — `.strip` removes it and truncates the slice, which is why the
// policy is part of this API rather than a separate pass.

import Foundation

// MARK: - Byte Access

private extension Data {
    func loadLEValue<T: FixedWidthInteger>(_: T.Type, at offset: Int) -> T {
        var value: T = .zero
        _ = Swift.withUnsafeMutableBytes(of: &value) { destination in
            copyBytes(to: destination, from: offset ..< offset + MemoryLayout<T>.size)
        }
        return T(littleEndian: value)
    }

    func loadBEValue<T: FixedWidthInteger>(_: T.Type, at offset: Int) -> T {
        var value: T = .zero
        _ = Swift.withUnsafeMutableBytes(of: &value) { destination in
            copyBytes(to: destination, from: offset ..< offset + MemoryLayout<T>.size)
        }
        return T(bigEndian: value)
    }

    mutating func storeLE(_ value: some FixedWidthInteger, at offset: Int) {
        Swift.withUnsafeBytes(of: value.littleEndian) { source in
            replaceSubrange(offset ..< offset + source.count, with: source)
        }
    }

    mutating func storeBE(_ value: some FixedWidthInteger, at offset: Int) {
        Swift.withUnsafeBytes(of: value.bigEndian) { source in
            replaceSubrange(offset ..< offset + source.count, with: source)
        }
    }

    mutating func zeroBytes(at offset: Int, count: Int) {
        guard count > 0 else { return }
        replaceSubrange(offset ..< offset + count, with: Data(repeating: 0, count: count))
    }

    func holds(_ offset: Int, _ length: Int) -> Bool {
        offset >= 0 && length >= 0 && offset + length <= count
    }
}

// MARK: - Result

/// What one injected load command ended up as, per architecture slice.
public struct CustomFirmwareDylibInjection: Sendable {
    /// Slice start in the file. 0 for a thin binary.
    public let sliceOffset: Int
    /// Slice size after injection (smaller than before when the signature was stripped).
    public let sliceSize: Int
    public let cpuType: Int32
    public let cpuSubtype: Int32
    /// Absolute file offset the new load command was written to.
    public let loadCommandOffset: Int
    public let loadCommandSize: Int
    public let isWeak: Bool
    /// True when LC_CODE_SIGNATURE and its blob were removed.
    public let removedCodeSignature: Bool
    /// Slots re-hashed under `.keepAndReattest`. Empty under `.strip`.
    public let rehashedSlots: [CustomFirmwareSlotRehash]
}

// MARK: - Injector

public enum CustomFirmwareInjectDylib {
    /// What to do about an existing LC_CODE_SIGNATURE.
    public enum CodeSignaturePolicy: Sendable {
        /// Drop the load command, the signature blob and the bytes it occupied,
        /// exactly as `insert_dylib` does by default. The CFW pipeline re-signs
        /// with ldid on the next line, so the binary is never left unsigned.
        case strip
        /// Keep the signature and recompute the slot hashes of the pages the
        /// injection touched, so the binary still verifies with no external
        /// signer. Only valid when the signature covers the header — i.e. every
        /// real Mach-O.
        case keepAndReattest
    }

    // MARK: Constants

    static let machMagic64: UInt32 = 0xFEED_FACF
    static let machMagic32: UInt32 = 0xFEED_FACE
    static let machCigam64: UInt32 = 0xCFFA_EDFE
    static let fatMagic: UInt32 = 0xCAFE_BABE
    static let fatMagic64: UInt32 = 0xCAFE_BABF

    static let lcSegment64: UInt32 = 0x19
    static let lcSymtab: UInt32 = 0x02
    static let lcCodeSignature: UInt32 = 0x1D
    static let lcLoadDylib: UInt32 = 0x0C
    static let lcLoadWeakDylib: UInt32 = 0x8000_0018

    /// sizeof(struct dylib_command).
    static let dylibCommandSize = 24
    /// A 4-byte pad is enough for the loader but codesign rejects it, which is
    /// the comment `insert_dylib` carries over the same constant.
    static let pathPadding = 8
    static let machHeader64Size = 32

    // MARK: Entry Points

    /// Insert a dylib load command into every architecture slice of `url`, in place.
    @discardableResult
    public static func inject(
        dylibPath: String,
        into url: URL,
        weak: Bool = true,
        policy: CodeSignaturePolicy = .strip,
        allowNonEmptyPadding: Bool = false,
    ) throws -> [CustomFirmwareDylibInjection] {
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw PatcherError.fileNotFound(url.path)
        }
        var data = try Data(contentsOfFileToRewrite: url)
        let injections = try inject(
            dylibPath: dylibPath,
            into: &data,
            weak: weak,
            policy: policy,
            allowNonEmptyPadding: allowNonEmptyPadding,
        )
        try data.write(to: url)
        return injections
    }

    /// Buffer form of `inject(dylibPath:into:weak:policy:)`.
    @discardableResult
    public static func inject(
        dylibPath: String,
        into data: inout Data,
        weak: Bool = true,
        policy: CodeSignaturePolicy = .strip,
        allowNonEmptyPadding: Bool = false,
    ) throws -> [CustomFirmwareDylibInjection] {
        if data.startIndex != 0 {
            data = Data(data)
        }
        guard data.holds(0, 4) else { throw PatcherError.invalidFormat("file is too small to be a Mach-O") }

        let options = Options(
            dylibPath: dylibPath,
            weak: weak,
            policy: policy,
            allowNonEmptyPadding: allowNonEmptyPadding,
        )
        switch data.loadBEValue(UInt32.self, at: 0) {
        case fatMagic:
            return try injectFat(into: &data, options: options)
        case fatMagic64:
            // `insert_dylib` refuses these too; no arm64e IPSW ships one.
            throw PatcherError.invalidFormat("64-bit fat binaries (FAT_MAGIC_64) are not supported")
        default:
            var sliceSize = data.count
            let injection = try injectSlice(
                into: &data,
                headerOffset: 0,
                sliceSize: &sliceSize,
                options: options,
            )
            if sliceSize < data.count {
                data = data.prefix(sliceSize)
            }
            return [injection]
        }
    }

    struct Options {
        let dylibPath: String
        let weak: Bool
        let policy: CodeSignaturePolicy
        let allowNonEmptyPadding: Bool
    }

    // MARK: Universal Binaries

    /// Re-pack a fat binary the way `insert_dylib` does: walk the slices in
    /// order, slide each one down to its alignment boundary behind the previous
    /// slice, inject, and truncate. Slices move because `.strip` makes earlier
    /// ones shorter.
    static func injectFat(into data: inout Data, options: Options) throws -> [CustomFirmwareDylibInjection] {
        let archCount = Int(data.loadBEValue(UInt32.self, at: 4))
        guard archCount > 0, data.holds(8, archCount * 20) else {
            throw PatcherError.invalidFormat("fat header declares \(archCount) architectures it does not have")
        }

        var injections: [CustomFirmwareDylibInjection] = []
        var fileSize = data.count
        var cursor = Int(data.loadBEValue(UInt32.self, at: 8 + 8))

        for index in 0 ..< archCount {
            let entry = 8 + index * 20
            let originalOffset = Int(data.loadBEValue(UInt32.self, at: entry + 8))
            let originalSize = Int(data.loadBEValue(UInt32.self, at: entry + 12))
            let align = Int(data.loadBEValue(UInt32.self, at: entry + 16))
            guard align < 32, data.holds(originalOffset, originalSize) else {
                throw PatcherError.invalidFormat("fat slice \(index) is out of bounds")
            }

            cursor = roundUp(cursor, to: 1 << align)
            if cursor != originalOffset {
                guard data.holds(cursor, originalSize) else {
                    throw PatcherError.invalidFormat("fat slice \(index) would be relocated past the end of the file")
                }
                let slice = Data(data[originalOffset ..< originalOffset + originalSize])
                data.replaceSubrange(cursor ..< cursor + originalSize, with: slice)
                // Zero whatever the move left behind, so the gap is not stale code.
                data.zeroBytes(
                    at: Swift.min(cursor, originalOffset) + originalSize,
                    count: abs(cursor - originalOffset),
                )
                data.storeBE(UInt32(cursor), at: entry + 8)
            }

            var sliceSize = originalSize
            try injections.append(injectSlice(
                into: &data,
                headerOffset: cursor,
                sliceSize: &sliceSize,
                options: options,
            ))

            if sliceSize < originalSize, index < archCount - 1 {
                data.zeroBytes(at: cursor + sliceSize, count: originalSize - sliceSize)
            }
            fileSize = cursor + sliceSize
            cursor += sliceSize
            data.storeBE(UInt32(sliceSize), at: entry + 12)
        }

        if fileSize < data.count {
            data = data.prefix(fileSize)
        }
        return injections
    }

    // MARK: One Slice

    static func injectSlice(
        into data: inout Data,
        headerOffset: Int,
        sliceSize: inout Int,
        options: Options,
    ) throws -> CustomFirmwareDylibInjection {
        guard data.holds(headerOffset, machHeader64Size) else {
            throw PatcherError.invalidFormat("Mach-O header at 0x\(String(headerOffset, radix: 16)) is truncated")
        }
        let magic = data.loadLEValue(UInt32.self, at: headerOffset)
        guard magic == machMagic64 else {
            let hint = magic == machMagic32
                ? "32-bit Mach-O"
                : (magic == machCigam64 ? "big-endian Mach-O" : "magic 0x\(String(magic, radix: 16))")
            throw PatcherError.invalidFormat("unsupported slice: \(hint)")
        }

        let cpuType = Int32(bitPattern: data.loadLEValue(UInt32.self, at: headerOffset + 4))
        let cpuSubtype = Int32(bitPattern: data.loadLEValue(UInt32.self, at: headerOffset + 8))
        let commandsOffset = headerOffset + machHeader64Size
        var ncmds = data.loadLEValue(UInt32.self, at: headerOffset + 16)
        var sizeofcmds = Int(data.loadLEValue(UInt32.self, at: headerOffset + 20))

        let layout = try scanLoadCommands(
            in: data,
            headerOffset: headerOffset,
            commandsOffset: commandsOffset,
            ncmds: Int(ncmds),
        )

        var removedCodeSignature = false
        if case .strip = options.policy, let signature = layout.codeSignature, layout.codeSignatureIsLast {
            try stripCodeSignature(
                from: &data,
                headerOffset: headerOffset,
                sliceSize: &sliceSize,
                signature: signature,
                layout: layout,
            )
            ncmds -= 1
            sizeofcmds -= signature.commandSize
            removedCodeSignature = true
        }

        // The command is `dylib_command` followed by the NUL-padded path. The
        // padding formula always leaves at least one NUL, matching insert_dylib.
        let pathBytes = Array(options.dylibPath.utf8)
        let paddedPathSize = (pathBytes.count & ~(pathPadding - 1)) + pathPadding
        let commandSize = dylibCommandSize + paddedPathSize
        let commandOffset = commandsOffset + sizeofcmds

        guard data.holds(commandOffset, commandSize), commandOffset + commandSize <= headerOffset + sliceSize else {
            throw PatcherError.invalidFormat(
                "no room for a \(commandSize)-byte load command at 0x\(String(commandOffset, radix: 16))",
            )
        }
        if !options.allowNonEmptyPadding,
           data[commandOffset ..< commandOffset + commandSize].contains(where: { $0 != 0 }) {
            // insert_dylib --all-yes overwrites here. Refusing is the whole
            // reason this is a Swift port: the bytes past the load commands are
            // the first section, and clobbering them is silent.
            throw PatcherError.invalidFormat(
                "load-command padding at 0x\(String(commandOffset, radix: 16)) is not empty; "
                    + "inserting would overwrite \(commandSize) bytes of the first section",
            )
        }

        var command = Data(capacity: commandSize)
        command.append(contentsOf: [0, 0, 0, 0, 0, 0, 0, 0])
        command.storeLE(options.weak ? lcLoadWeakDylib : lcLoadDylib, at: 0)
        command.storeLE(UInt32(commandSize), at: 4)
        command.append(contentsOf: [0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0])
        command.storeLE(UInt32(dylibCommandSize), at: 8) // dylib.name offset
        command.storeLE(UInt32(0), at: 12) // timestamp
        command.storeLE(UInt32(0), at: 16) // current_version
        command.storeLE(UInt32(0), at: 20) // compatibility_version
        command.append(contentsOf: pathBytes)
        command.append(Data(repeating: 0, count: paddedPathSize - pathBytes.count))
        data.replaceSubrange(commandOffset ..< commandOffset + commandSize, with: command)

        ncmds += 1
        sizeofcmds += commandSize
        data.storeLE(ncmds, at: headerOffset + 16)
        data.storeLE(UInt32(sizeofcmds), at: headerOffset + 20)

        var rehashed: [CustomFirmwareSlotRehash] = []
        if case .keepAndReattest = options.policy {
            rehashed = try reattestSlice(
                in: &data,
                headerOffset: headerOffset,
                sliceSize: sliceSize,
                touched: [
                    (headerOffset + 16) ..< (headerOffset + 24),
                    commandOffset ..< commandOffset + commandSize,
                ],
            )
        }

        return CustomFirmwareDylibInjection(
            sliceOffset: headerOffset,
            sliceSize: sliceSize,
            cpuType: cpuType,
            cpuSubtype: cpuSubtype,
            loadCommandOffset: commandOffset,
            loadCommandSize: commandSize,
            isWeak: options.weak,
            removedCodeSignature: removedCodeSignature,
            rehashedSlots: rehashed,
        )
    }

    // MARK: Load Command Scan

    struct CodeSignatureCommand {
        let commandOffset: Int
        let commandSize: Int
        /// Slice-relative, as stored.
        let dataOffset: Int
        let dataSize: Int
    }

    struct SliceLayout {
        var codeSignature: CodeSignatureCommand?
        var codeSignatureIsLast = false
        /// Offset of the __LINKEDIT LC_SEGMENT_64 command, and its slice-relative extent.
        var linkEditCommandOffset: Int?
        var linkEditFileOffset = 0
        var linkEditFileSize = 0
        var symtabCommandOffset: Int?
    }

    static func scanLoadCommands(
        in data: Data,
        headerOffset _: Int,
        commandsOffset: Int,
        ncmds: Int,
    ) throws -> SliceLayout {
        var layout = SliceLayout()
        var offset = commandsOffset
        for index in 0 ..< ncmds {
            guard data.holds(offset, 8) else {
                throw PatcherError.invalidFormat("load command \(index) runs past the end of the file")
            }
            let cmd = data.loadLEValue(UInt32.self, at: offset)
            let cmdsize = Int(data.loadLEValue(UInt32.self, at: offset + 4))
            guard cmdsize >= 8, data.holds(offset, cmdsize) else {
                throw PatcherError.invalidFormat("load command \(index) declares an impossible size \(cmdsize)")
            }

            switch cmd {
            case lcCodeSignature:
                guard data.holds(offset, 16) else {
                    throw PatcherError.invalidFormat("LC_CODE_SIGNATURE is truncated")
                }
                layout.codeSignature = CodeSignatureCommand(
                    commandOffset: offset,
                    commandSize: cmdsize,
                    dataOffset: Int(data.loadLEValue(UInt32.self, at: offset + 8)),
                    dataSize: Int(data.loadLEValue(UInt32.self, at: offset + 12)),
                )
                layout.codeSignatureIsLast = index == ncmds - 1
            case lcSegment64:
                guard data.holds(offset, 72) else {
                    throw PatcherError.invalidFormat("LC_SEGMENT_64 is truncated")
                }
                let name = segmentName(in: data, at: offset + 8)
                if name == "__LINKEDIT" {
                    layout.linkEditCommandOffset = offset
                    layout.linkEditFileOffset = Int(data.loadLEValue(UInt64.self, at: offset + 40))
                    layout.linkEditFileSize = Int(data.loadLEValue(UInt64.self, at: offset + 48))
                }
            case lcSymtab:
                guard data.holds(offset, 24) else {
                    throw PatcherError.invalidFormat("LC_SYMTAB is truncated")
                }
                layout.symtabCommandOffset = offset
            default:
                break
            }
            offset += cmdsize
        }
        return layout
    }

    static func segmentName(in data: Data, at offset: Int) -> String {
        let bytes = data[offset ..< offset + 16].prefix { $0 != 0 }
        return String(decoding: bytes, as: UTF8.self)
    }

    // MARK: Code Signature Removal

    /// Remove the signature the way `insert_dylib` does.
    ///
    /// When the signature sits at the very end of __LINKEDIT and __LINKEDIT sits
    /// at the very end of the slice — true for every linker output — the slice is
    /// shortened instead of just blanked, __LINKEDIT shrinks with it, and the
    /// string table is stretched over the gap left between it and the old
    /// signature so the linkedit contents stay contiguous. Anything else falls
    /// back to zeroing the blob in place.
    static func stripCodeSignature(
        from data: inout Data,
        headerOffset: Int,
        sliceSize: inout Int,
        signature: CodeSignatureCommand,
        layout: SliceLayout,
    ) throws {
        data.zeroBytes(at: signature.commandOffset, count: signature.commandSize)

        let canTruncate = layout.linkEditCommandOffset != nil
            && layout.linkEditFileOffset + layout.linkEditFileSize == sliceSize
            && signature.dataOffset + signature.dataSize == sliceSize
        guard canTruncate, let linkEditOffset = layout.linkEditCommandOffset else {
            guard data.holds(headerOffset + signature.dataOffset, signature.dataSize) else {
                throw PatcherError.invalidFormat("LC_CODE_SIGNATURE points outside the file")
            }
            data.zeroBytes(at: headerOffset + signature.dataOffset, count: signature.dataSize)
            return
        }

        sliceSize -= signature.dataSize

        // The string table is the last thing in __LINKEDIT before the signature,
        // and its recorded size can fall a few bytes short of where the signature
        // began (alignment padding). Stretch it to the new slice end so nothing
        // is left unaccounted for; leave it alone if the gap is implausible.
        if let symtabOffset = layout.symtabCommandOffset {
            let stringOffset = Int(data.loadLEValue(UInt32.self, at: symtabOffset + 16))
            let stringSize = Int(data.loadLEValue(UInt32.self, at: symtabOffset + 20))
            let difference = stringOffset + stringSize - sliceSize
            if difference >= -0x10, difference <= 0 {
                data.storeLE(UInt32(stringSize - difference), at: symtabOffset + 20)
            }
        }

        let newLinkEditFileSize = layout.linkEditFileSize - signature.dataSize
        data.storeLE(UInt64(newLinkEditFileSize), at: linkEditOffset + 48)
        data.storeLE(UInt64(roundUp(newLinkEditFileSize, to: 0x1000)), at: linkEditOffset + 32)
    }

    // MARK: Re-attestation

    /// Re-hash the touched pages of one slice.
    ///
    /// The CodeDirectory's offsets are slice-relative, so a fat slice has to be
    /// re-attested on its own bytes and spliced back rather than re-attested in
    /// place against whole-file offsets.
    static func reattestSlice(
        in data: inout Data,
        headerOffset: Int,
        sliceSize: Int,
        touched: [Range<Int>],
    ) throws -> [CustomFirmwareSlotRehash] {
        var slice = Data(data[headerOffset ..< headerOffset + sliceSize])
        let offsets = touched.flatMap { range in range.map { $0 - headerOffset } }
        let records = try CustomFirmwareMachOCodeSignature.reattest(&slice, modifiedOffsets: offsets)
        data.replaceSubrange(headerOffset ..< headerOffset + sliceSize, with: slice)
        return records
    }

    // MARK: Helpers

    static func roundUp(_ value: Int, to alignment: Int) -> Int {
        guard alignment > 1 else { return value }
        return (value + alignment - 1) & ~(alignment - 1)
    }
}
