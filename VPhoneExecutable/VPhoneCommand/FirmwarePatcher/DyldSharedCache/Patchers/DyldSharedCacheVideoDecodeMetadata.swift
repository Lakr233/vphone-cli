import Foundation
import MachO
import VPhonePatchKit

/// Discovers the private contracts used by VideoDecodeFix. It writes metadata,
/// not shared-cache instructions. The guest verifies the UUID and every saved
/// prefix before installing process-private detours during daemon construction.
public enum DyldSharedCacheVideoDecodeMetadata {
    static let image = "/System/Library/Frameworks/VideoToolbox.framework/VideoToolbox"
    static let coreMedia = "/System/Library/Frameworks/CoreMedia.framework/CoreMedia"
    static let platform = "/usr/lib/system/libsystem_platform.dylib"
    static let dispatch = "/usr/lib/system/libdispatch.dylib"

    /// An optional repair can skip an unknown ABI or private code layout.
    /// Corrupt cache data, I/O failures and metadata errors must still abort
    /// installation. Use only around discovery, never installation writes.
    public static func isUnsupportedLayout(_ error: any Error) -> Bool {
        switch error {
        case PatcherError.patchSiteNotFound,
             DyldSharedCacheError.symbolNotFound,
             DyldSharedCacheError.imageNotFound,
             DyldSharedCacheError.localSymbolsMissing:
            true
        default:
            false
        }
    }

    public static func metadata(directory: URL) throws -> Data {
        let chunks = try DyldSharedCacheChunkSet(directory: directory)
        let resolver = try DyldSharedCacheSymbolResolver(chunks: chunks)
        let pointers = try DyldSharedCache(path: chunks.mainCacheURL)
        try resolver.requireLocalSymbols()
        let decoder = ARM64Disassembler()
        let header = try resolver.headerAddress(ofImage: image)
        let uuid = try imageUUID(chunks.readAtVMA(header, length: 16384))
        let functions = try resolver.functionStarts(inImage: image)
        // These are bound with dlsym in the guest. A local symbol alone is
        // insufficient, even if all of the surrounding code still matches.
        for (path, name) in [(image, "VTVideoDecoderGetCMBaseObject"),
                             (coreMedia, "CMBaseObjectGetDerivedStorage"),
                             (coreMedia, "FigCFWeakReferenceHolderCopyReferencedObject")] {
            guard try resolver.symbols(inImage: path)["_" + name]?.source == .exportTrie else {
                throw PatcherError.patchSiteNotFound("VideoDecode: runtime export unavailable: \(name)")
            }
        }
        func address(_ name: String, _ path: String = image) throws -> UInt64 {
            try resolver.address(of: "_" + name, inImage: path)
        }
        func body(_ start: UInt64, _ length: Int = 2048) throws -> [ARM64Instruction] {
            let count = try functionLength(start, starts: functions, limit: length)
            return decoder.disassemble(try chunks.readAtVMA(start, length: count), at: start)
        }
        func target(_ instruction: ARM64Instruction) throws -> UInt64? {
            guard var destination = directTarget(instruction) else { return nil }
            for _ in 0..<4 {
                let stub = decoder.disassemble(try chunks.readAtVMA(destination, length: 16), at: destination)
                if let direct = stubTarget(stub) { destination = direct }
                else if let slot = authenticatedStubSlot(stub), let pointer = try pointers.pointer(at: slot),
                        pointer.auth, pointer.addressDiversity, !pointer.keyIsData, pointer.diversity == 0 {
                    destination = pointer.target
                } else { return destination }
            }
            return destination
        }
        func calls(_ instructions: [ARM64Instruction], _ destination: UInt64) throws -> [Int] {
            try instructions.indices.filter { try instructions[$0].mnemonic == "bl" && target(instructions[$0]) == destination }
        }
        func unique(_ values: [UInt64], _ label: String) throws -> UInt64 {
            guard Set(values).count == 1, let value = values.first else {
                throw PatcherError.patchSiteNotFound("VideoDecode: expected one \(label), found \(Set(values).count)")
            }
            return value
        }

        let handler = try address("__ParavirtualizedVideoDecoder_CreateInstanceWithSpecification_block_invoke")
        let dispatchBlock = try address("__vtParavirtualizationGuestDispatchOneMessageFromHost_block_invoke")
        let receiver = try address("__vtParavirtualizationGuestSetup_block_invoke_3")
        let invalidate = try address("ParavirtualizedVideoDecoder_Invalidate")
        let wait = try address("VTParavirtualizationReplyClerkWaitForReply")
        let lock = try address("os_unfair_lock_lock", platform)
        let unlock = try address("os_unfair_lock_unlock", platform)
        let emit = try address("VTDecoderSessionEmitDecodedFrame")
        let makeMessage = try address("VTParavirtualizationCreateMessageAndByteStream")
        let getStorage = try address("CMBaseObjectGetDerivedStorage", coreMedia)
        let sendAsync = try address("dispatch_async", dispatch)
        let semaphoreWait = try address("dispatch_semaphore_wait", dispatch)

        let invalidation = try body(invalidate)
        let fields = try storageFields(invalidation, lock: lock, unlock: unlock,
                                       getStorage: getStorage, makeMessage: makeMessage, target: target)
        let handlerBody = try body(handler, 8192)
        guard try verifiesOutputLock(handlerBody, offset: fields.lock, lock: lock, unlock: unlock, emit: emit, target: target),
              !(try calls(handlerBody, address("FigCFWeakReferenceHolderCopyReferencedObject", coreMedia))).isEmpty
        else { throw PatcherError.patchSiteNotFound("VideoDecode: retained PV frame output and lock scope not verified") }

        let dispatchBody = try body(dispatchBlock, 256)
        let messageOffset = try blockMessageOffset(dispatchBody)
        let receiveBody = try body(receiver)
        let receiverCalls = try calls(receiveBody, sendAsync)
        let dispatchReturns = receiverCalls.compactMap { index -> UInt64? in
            let prefix = Array(receiveBody[max(0, index - 24)..<index])
            return materializedAddresses(prefix).contains(dispatchBlock) ? receiveBody[index].address + 4 : nil
        }
        let dispatchReturn = try unique(dispatchReturns, "message-dispatch call site")
        let waitBody = try body(wait)
        let waitReturn = try unique(try calls(waitBody, semaphoreWait).map { waitBody[$0].address + 4 }, "reply semaphore wait")

        // There are multiple file-local functions with this name. Choose the
        // XPC server callback by its transport calls, never symbol-table order.
        let outputCandidates = try resolver.addresses(of: "_DecompressionOutputCallback", inImage: image)
        let figWait = try address("FigSemaphoreWaitRelative", coreMedia)
        let xpcSend = try address("xpc_connection_send_message", "/usr/lib/system/libxpc.dylib")
        let output = try unique(try outputCandidates.filter { candidate in
            let instructions = try body(candidate)
            let waits = try calls(instructions, figWait)
            let sends = try calls(instructions, xpcSend)
            return !waits.isEmpty && !sends.isEmpty
        }, "XPC output callback")

        // Client invalidation must release both XPC/event-link output waits
        // before scheduling decoder teardown; the lifetime gate relies on it.
        let xpcInvalidation = try body(address("dssxpc_invalidateSession"))
        guard !(try calls(xpcInvalidation, address("FigSemaphoreSignal", coreMedia))).isEmpty,
              !(try calls(xpcInvalidation, address("FigOSEventLinkRemoteInvalidate", coreMedia))).isEmpty
        else { throw PatcherError.patchSiteNotFound("VideoDecode: XPC cancellation does not release output waits") }

        // Matches VPVideoDecodeMetadata.h. All addresses are discovered from
        // this cache; no per-build address or file offset is shipped in code.
        let entries: [UInt64] = try [
            address("VTParavirtualizationGuestInstallHandlerForUUID"),
            address("VTParavirtualizationGuestRemoveHandlerForUUID"),
            handler, dispatchBlock, dispatchReturn, output,
            address("VTDecompressionSessionCreateWithOptions"), invalidate,
            address("VTParavirtualizationGuestSendMessageToHostAndCopyReplySync"),
            waitReturn, address("VTParavirtualizationMessageGetMessageTypeAndFlagsAndGuestUUID"),
        ]
        for index in [0, 1, 6, 7, 8] {
            let prologue = decoder.disassemble(try chunks.readAtVMA(entries[index], length: 16), at: entries[index])
            guard safePrologue(prologue) else {
                throw PatcherError.patchSiteNotFound("VideoDecode: unsupported detour prologue at entry \(index)")
            }
        }
        return try encode(header: header, uuid: uuid, lock: fields.lock, uuidOffset: fields.uuid,
                          message: messageOffset, entries: entries, read: { try chunks.readAtVMA($0, length: $1) })
    }

    // MARK: - Semantic checks (also exercised without firmware fixtures)

    static func functionLength(_ start: UInt64, starts: [UInt64], limit: Int) throws -> Int {
        guard let index = starts.firstIndex(of: start), index + 1 < starts.count,
              starts[index + 1] > start, starts[index + 1] - start <= limit,
              (starts[index + 1] - start) % 4 == 0 else {
            throw PatcherError.patchSiteNotFound("VideoDecode: bounded function extent missing at \(start)")
        }
        return Int(starts[index + 1] - start)
    }

    static func directTarget(_ instruction: ARM64Instruction) -> UInt64? {
        guard ["b", "bl"].contains(instruction.mnemonic), let operand = instruction.detail?.operands.first,
              operand.type == .immediate, operand.imm > 0 else { return nil }
        return UInt64(operand.imm)
    }

    static func materializedAddresses(_ code: [ARM64Instruction]) -> Set<UInt64> {
        var values = Set<UInt64>()
        for index in code.indices.dropLast() {
            let page = code[index], add = code[index + 1]
            guard page.mnemonic == "adrp", add.mnemonic == "add",
                  let p = page.detail?.operands, p.count == 2, p[0].type == .register, p[1].type == .immediate,
                  let a = add.detail?.operands, a.count == 3, a[0].reg == p[0].reg, a[1].reg == p[0].reg,
                  a[2].type == .immediate, a[2].imm >= 0, a[2].shift.amount == 0 else { continue }
            values.insert(UInt64(bitPattern: p[1].imm) &+ UInt64(a[2].imm))
        }
        return values
    }

    static func stubTarget(_ code: [ARM64Instruction]) -> UInt64? {
        guard code.count >= 3, code[2].mnemonic == "br",
              code[2].detail?.operands.first?.reg == .x(16),
              code[0].detail?.operands.first?.reg == .x(16)
        else { return nil }
        return materializedAddresses(Array(code.prefix(2))).first
    }

    /// ADRP X17; ADD X17,X17,#low; LDR X16,[X17]; BRAA X16,X17.
    /// The GOT word is a slide-info pointer, not an on-disk absolute address.
    static func authenticatedStubSlot(_ code: [ARM64Instruction]) -> UInt64? {
        guard code.count >= 4, code[0].detail?.operands.first?.reg == .x(17),
              let slot = materializedAddresses(Array(code.prefix(2))).first,
              code[2].mnemonic == "ldr", let load = code[2].detail?.operands, load.count == 2,
              load[0].reg == .x(16), load[1].type == .memory,
              load[1].mem.base == .x(17), load[1].mem.index == .invalid, load[1].mem.disp == 0,
              code[3].mnemonic == "braa", let branch = code[3].detail?.operands, branch.count == 2,
              branch[0].reg == .x(16), branch[1].reg == .x(17) else { return nil }
        return slot
    }

    static func addOffset(_ instruction: ARM64Instruction, destination: ARM64Register,
                          base: ARM64Register? = nil) -> (base: ARM64Register, offset: UInt32)? {
        guard instruction.mnemonic == "add", let o = instruction.detail?.operands, o.count == 3,
              o[0].type == .register, o[0].reg == destination, o[1].type == .register,
              base == nil || base == o[1].reg, o[2].type == .immediate, o[2].shift.amount == 0,
              let offset = UInt32(exactly: o[2].imm) else { return nil }
        return (o[1].reg, offset)
    }

    static func storageFields(_ code: [ARM64Instruction], lock: UInt64, unlock: UInt64,
                              getStorage: UInt64, makeMessage: UInt64,
                              target: (ARM64Instruction) throws -> UInt64?) throws -> (lock: UInt32, uuid: UInt32) {
        var candidates: [(base: ARM64Register, offset: UInt32, index: Int)] = []
        for index in code.indices where index >= 2 && index + 2 < code.count {
            guard code[index].mnemonic == "stp", let zero = code[index].detail?.operands, zero.count == 3,
                  zero[0].reg == .xzr, zero[1].reg == .xzr, zero[2].type == .memory,
                  zero[2].mem.disp == 0, zero[2].mem.index == .invalid,
                  zero[2].mem.base != .sp, zero[2].mem.base != .x(29),
                  let take = addOffset(code[index - 2], destination: .x(0), base: zero[2].mem.base),
                  let give = addOffset(code[index + 1], destination: .x(0), base: zero[2].mem.base),
                  take.offset == give.offset, take.offset >= 16, take.offset < 256, take.offset % 4 == 0,
                  code[index - 1].mnemonic == "bl", code[index + 2].mnemonic == "bl",
                  try target(code[index - 1]) == lock, try target(code[index + 2]) == unlock else { continue }
            candidates.append((take.base, take.offset, index))
        }
        guard candidates.count == 1, let candidate = candidates.first,
              let storageCall = try code.firstIndex(where: { try $0.mnemonic == "bl" && target($0) == getStorage }),
              let messageCall = try code.indices.first(where: { try $0 > storageCall && code[$0].mnemonic == "bl" && target(code[$0]) == makeMessage }),
              messageCall < candidate.index
        else { throw PatcherError.patchSiteNotFound("VideoDecode: unique session-pointer invalidation lock missing") }
        var aliases: Set<ARM64Register> = [.x(0)]
        var uuidArgument: UInt32?, uuid: UInt32?
        for index in (storageCall + 1)..<candidate.index {
            let instruction = code[index]
            if index == messageCall { uuid = uuidArgument }
            let addition = addOffset(instruction, destination: .x(2))
            let nextUUID = addition.flatMap { aliases.contains($0.base) ? $0.offset : nil }
            var copiedAlias: ARM64Register?
            if instruction.mnemonic == "mov", let o = instruction.detail?.operands, o.count == 2,
               o[0].type == .register, o[1].type == .register, aliases.contains(o[1].reg) { copiedAlias = o[0].reg }
            aliases = aliases.filter { !writes(instruction, register: $0) }
            if let copiedAlias { aliases.insert(copiedAlias) }
            if writes(instruction, register: .x(2)) { uuidArgument = nil }
            if let nextUUID { uuidArgument = nextUUID }
        }
        guard aliases.contains(candidate.base), let uuid,
              uuid >= candidate.offset + 4, uuid < 256, uuid % 8 == 0 else {
            throw PatcherError.patchSiteNotFound("VideoDecode: decoder UUID field not verified")
        }
        return (candidate.offset, uuid)
    }

    static func writes(_ instruction: ARM64Instruction, register: ARM64Register) -> Bool {
        let number = (0..<31).first { register == .x($0) }
        if instruction.isCall, let number, number < 19 || number == 30 { return true }
        return instruction.detail?.operands.contains { operand in
            operand.type == .register && operand.writesRegister &&
                (operand.reg == register || number.map { operand.reg == .w($0) } == true)
        } ?? false
    }

    static func verifiesOutputLock(_ code: [ARM64Instruction], offset: UInt32, lock: UInt64, unlock: UInt64,
                                   emit: UInt64, target: (ARM64Instruction) throws -> UInt64?) throws -> Bool {
        let byAddress = Dictionary(uniqueKeysWithValues: code.enumerated().map { ($0.element.address, $0.offset) })
        for index in code.indices where index >= 8 && index + 2 < code.count {
            guard code[index].mnemonic == "bl", try target(code[index]) == emit,
                  let take = addOffset(code[index - 8], destination: .x(0)), take.offset == offset,
                  code[index - 7].mnemonic == "bl",
                  try target(code[index - 7]) == lock,
                  code[index - 6].mnemonic == "ldr", let load = code[index - 6].detail?.operands, load.count == 2,
                  load[0].reg == .x(0), load[1].type == .memory, load[1].mem.base == take.base,
                  load[1].mem.index == .invalid, load[1].mem.disp == 0,
                  code[index + 2].mnemonic == "b", let destination = directTarget(code[index + 2]),
                  let releaseIndex = byAddress[destination], releaseIndex + 1 < code.count,
                  let give = addOffset(code[releaseIndex], destination: .x(0), base: take.base), give.offset == offset,
                  code[releaseIndex + 1].mnemonic == "bl",
                  try target(code[releaseIndex + 1]) == unlock else { continue }
            return true
        }
        return false
    }

    static func blockMessageOffset(_ code: [ARM64Instruction]) throws -> UInt32 {
        var aliases: Set<ARM64Register> = [.x(0)]
        var messages = Set<UInt32>()
        var holders = Set<UInt32>()
        var handlers = Set<UInt32>()
        for instruction in code {
            guard let o = instruction.detail?.operands else { continue }
            var copiedAlias: ARM64Register?
            if instruction.mnemonic == "mov", o.count == 2, o[0].type == .register,
               o[1].type == .register, aliases.contains(o[1].reg) { copiedAlias = o[0].reg }
            if instruction.mnemonic == "ldp", o.count == 3, o[2].type == .memory,
               aliases.contains(o[2].mem.base), o[2].mem.index == .invalid, o[2].mem.disp >= 0,
               o[0].reg == .x(1), o[1].reg == .x(2) {
                messages.insert(UInt32(o[2].mem.disp)); holders.insert(UInt32(o[2].mem.disp) + 8)
            }
            if instruction.mnemonic == "ldr", o.count == 2, o[1].type == .memory,
               aliases.contains(o[1].mem.base), o[1].mem.index == .invalid, o[1].mem.disp >= 0 {
                let field = UInt32(o[1].mem.disp)
                if o[0].reg == .x(1) { messages.insert(field) }
                else if o[0].reg == .x(2) { holders.insert(field) }
                else { handlers.insert(field) }
            }
            // Once a register is overwritten (or a caller-saved alias crosses
            // a call), a later load through it is not a block capture.
            aliases = aliases.filter { !writes(instruction, register: $0) }
            if let copiedAlias { aliases.insert(copiedAlias) }
        }
        let candidates = messages.filter { $0 >= 40 && $0 <= 96 && $0 % 8 == 0 && holders.contains($0 + 8) && handlers.contains($0 - 8) }
        guard candidates.count == 1, let offset = candidates.first else {
            throw PatcherError.patchSiteNotFound("VideoDecode: dispatch block capture layout not verified")
        }
        return offset
    }

    static func safePrologue(_ instructions: [ARM64Instruction]) -> Bool {
        instructions.count == 4 && instructions.enumerated().allSatisfy { index, instruction in
            // MISFixDetour re-signs the PC-bound X1 form for its original PC;
            // that expansion uses scratch registers and is safe only at entry.
            let admitted = instruction.mnemonic == "pacibsppc" ? index == 0 :
                ["pacibsp", "stp", "sub", "add", "mov", "nop"].contains(instruction.mnemonic)
            // The absolute jump back uses IP0. Do not relocate a prologue
            // that establishes an x16/w16 value for the undisplaced body.
            return instruction.isDecoded && admitted && !instruction.isJump && !instruction.isCall && !instruction.isReturn
                && !writes(instruction, register: .x(16))
        }
    }

    static func imageUUID(_ commands: Data) throws -> Data {
        func word(_ offset: Int) -> UInt32 { commands.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: offset, as: UInt32.self).littleEndian } }
        guard commands.count >= 32, word(0) == MH_MAGIC_64, word(20) <= commands.count - 32 else {
            throw PatcherError.patchVerificationFailed("VideoDecode: Mach-O header bounds")
        }
        // The shipped library uses the arm64e iOS ABI (also used by iPadOS).
        // X1 is an extension of it; plain arm64 and other Mach-O platforms
        // need their own runtime build, regardless of matching symbol names.
        let subtype = word(8) & 0x00FF_FFFF
        guard word(4) == UInt32(CPU_TYPE_ARM64),
              subtype == UInt32(CPU_SUBTYPE_ARM64E) || subtype == 12 /* ARM64E_X1 */ else {
            throw PatcherError.patchSiteNotFound("VideoDecode: requires an arm64e guest cache")
        }
        var cursor = 32
        let end = 32 + Int(word(20))
        var uuid: Data?
        var platform: UInt32?
        for _ in 0..<word(16) {
            guard cursor + 8 <= end else { throw PatcherError.patchVerificationFailed("VideoDecode: load command bounds") }
            let size = Int(word(cursor + 4))
            guard size >= 8, size <= end - cursor else { throw PatcherError.patchVerificationFailed("VideoDecode: load command size") }
            if word(cursor) == LC_UUID, size == 24 {
                guard uuid == nil else { throw PatcherError.patchVerificationFailed("VideoDecode: duplicate UUID") }
                uuid = commands.subdata(in: cursor + 8..<cursor + 24)
            }
            if word(cursor) == LC_BUILD_VERSION {
                guard size >= 24, platform == nil else {
                    throw PatcherError.patchVerificationFailed("VideoDecode: invalid build platform")
                }
                platform = word(cursor + 8)
            }
            cursor += size
        }
        guard cursor == end, let uuid else { throw PatcherError.patchVerificationFailed("VideoDecode: UUID missing") }
        guard platform == MachOBuildPlatform.iOS else {
            throw PatcherError.patchSiteNotFound("VideoDecode: requires the iOS/iPadOS binary platform")
        }
        return uuid
    }

    static func encode(header: UInt64, uuid: Data, lock: UInt32, uuidOffset: UInt32, message: UInt32,
                       entries: [UInt64], read: (UInt64, Int) throws -> Data) throws -> Data {
        guard uuid.count == 16, entries.count == 11 else { throw PatcherError.patchVerificationFailed("VideoDecode: metadata contract") }
        var result = Data("VPVD\u{1}\0\0\0".utf8)
        result.append(uuid)
        func append<T: FixedWidthInteger>(_ value: T) {
            var little = value.littleEndian
            withUnsafeBytes(of: &little) { result.append(contentsOf: $0) }
        }
        for value in [lock, uuidOffset, message, UInt32(entries.count)] { append(value) }
        for address in entries {
            guard address >= header, address - header <= 64 * 1024 * 1024, address % 4 == 0 else {
                throw PatcherError.patchSiteNotFound("VideoDecode: entry is outside the supported framework span")
            }
            append(address - header)
            let prefix = try read(address, 16)
            guard prefix.count == 16 else { throw PatcherError.patchVerificationFailed("VideoDecode: incomplete original code") }
            result.append(prefix)
        }
        return result
    }
}
