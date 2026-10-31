import Foundation
import VPhonePatchKit

/// Enables HomeView's entitled environment service on retail installations.
/// The entitlement rejection remains intact; only the following internal-install
/// branch is removed. Discovery is scoped to BreadBoardServices and verifies
/// its entitlement and distinct rejection messages before admitting one site.
public enum DyldSharedCacheHomeViewEnvironmentPatcher {
    public struct Failure: Error, CustomStringConvertible { public let description: String }
    public struct Site: Sendable {
        public let address: UInt64
        public let before: Data
        public let replacement: Data
        public let alreadyPatched: Bool
    }

    static let servicesImage = "/System/Library/PrivateFrameworks/BreadBoardServices.framework/BreadBoardServices"
    static let foundationImage = "/System/Library/PrivateFrameworks/BreadBoardFoundation.framework/BreadBoardFoundation"
    static let getterSymbol = "_$s20BreadBoardFoundation8PlatformO17isInternalInstallSbvgZ"
    static let entitlement = "com.apple.private.breadboard.environment.read-write"
    static let notEntitled = "Client is not entitled {client.pid=%d}"
    static let unavailable = "Service is unavailable"

    public static func discover(in chunks: DyldSharedCacheChunkSet) throws -> Site {
        let resolver = try DyldSharedCacheSymbolResolver(chunks: chunks)
        let getter = try resolver.address(of: getterSymbol, inImage: foundationImage)
        let headerAddress = try resolver.headerAddress(ofImage: servicesImage)
        let prefix = try chunks.readAtVMA(headerAddress, length: 32)
        guard prefix.loadLE(UInt32.self, at: 0) == 0xFEED_FACF else {
            throw Failure(description: "BreadBoardServices has no Mach-O header")
        }
        let commandBytes = Int(prefix.loadLE(UInt32.self, at: 20))
        guard commandBytes <= 1_048_576 else {
            throw Failure(description: "BreadBoardServices load commands are oversized")
        }
        let header = try chunks.readAtVMA(headerAddress, length: 32 + commandBytes)
        let sections = MachOParser.parseSections(from: header)
        guard let text = sections["__TEXT,__text"], let strings = sections["__TEXT,__cstring"],
              let logs = sections["__TEXT,__oslogstring"],
              text.size > 0, text.size <= 16_777_216, text.size % 4 == 0,
              strings.size > 0, strings.size <= 16_777_216,
              logs.size > 0, logs.size <= 16_777_216
        else { throw Failure(description: "BreadBoardServices discovery sections missing or invalid") }
        func literal(_ value: String, in section: MachOSectionInfo) throws -> UInt64 {
            let literals = try chunks.readAtVMA(section.address, length: Int(section.size))
            let needle = Data((value + "\0").utf8)
            guard let range = literals.range(of: needle),
                  literals.range(of: needle, in: range.upperBound ..< literals.endIndex) == nil
            else { throw Failure(description: "BreadBoardServices literal missing or ambiguous: \(value)") }
            return section.address + UInt64(range.lowerBound)
        }
        let decoder = ARM64Disassembler()
        let instructions = decoder.disassemble(
            try chunks.readAtVMA(text.address, length: Int(text.size)), at: text.address,
        )
        let sites = findSites(
            in: instructions, getter: getter,
            entitlement: try literal(entitlement, in: strings),
            notEntitled: try literal(notEntitled, in: logs),
            unavailable: try literal(unavailable, in: logs),
            readStub: { address in
                decoder.disassemble(try chunks.readAtVMA(address, length: 12), at: address)
            },
        )
        return try uniqueSite(sites)
    }

    public static func patch(in chunks: DyldSharedCacheChunkSet, dryRun: Bool = false) throws -> Site {
        let site = try discover(in: chunks)
        guard !dryRun else { return site }
        let span = DyldSharedCacheWriteSpan(vma: site.address, length: 4)
        let preview = try DyldSharedCacheCodeSignature.reattest(
            in: chunks, modifiedSpans: [span], dryRun: true, log: nil,
        )
        guard preview.isFullyAttested, preview.pagesAttested == 1 else {
            throw Failure(description: "cannot attest HomeView environment service page")
        }
        if !site.alreadyPatched { try chunks.write(at: site.address, site.replacement) }
        let result = try DyldSharedCacheCodeSignature.reattest(in: chunks, modifiedSpans: [span])
        guard result.isFullyAttested, result.pagesAttested == 1,
              try chunks.readAtVMA(site.address, length: 4) == site.replacement
        else { throw Failure(description: "HomeView environment service page verification failed") }
        return site
    }

    static func uniqueSite(_ sites: [Site]) throws -> Site {
        guard sites.count == 1, let site = sites.first else {
            throw Failure(description: "HomeView environment service gate missing or ambiguous")
        }
        return site
    }

    /// Direct import stub used by this cache: ADRP X16; ADD X16,X16,#low; BR X16.
    /// Reject pointer loads, authenticated dispatch, and changed scratch registers.
    static func stubDestination(_ code: [ARM64Instruction]) -> UInt64? {
        guard code.count == 3, code[0].detail?.operands.first?.reg == .x(16),
              code[1].detail?.operands.first?.reg == .x(16), code[2].mnemonic == "br",
              let branch = code[2].detail?.operands, branch.count == 1,
              branch[0].type == .register, branch[0].reg == .x(16)
        else { return nil }
        return materializedAddress(code[0], code[1])
    }

    static func materializedAddress(_ page: ARM64Instruction, _ add: ARM64Instruction) -> UInt64? {
        guard page.isDecoded, add.isDecoded, page.address + 4 == add.address,
              page.mnemonic == "adrp", add.mnemonic == "add",
              let p = page.detail?.operands, p.count == 2,
              p[0].type == .register, p[1].type == .immediate, p[1].imm > 0,
              let a = add.detail?.operands, a.count == 3,
              a[0].type == .register, a[1].type == .register, a[1].reg == p[0].reg,
              a[2].type == .immediate, a[2].imm >= 0, a[2].imm < 4096,
              a[2].shift.amount == 0
        else { return nil }
        return UInt64(p[1].imm) + UInt64(a[2].imm)
    }

    static func immediate(_ instruction: ARM64Instruction, _ index: Int) -> UInt64? {
        guard let operands = instruction.detail?.operands, operands.indices.contains(index),
              operands[index].type == .immediate, operands[index].imm > 0
        else { return nil }
        return UInt64(operands[index].imm)
    }

    static func literalReferences(_ instructions: ArraySlice<ARM64Instruction>, to address: UInt64) -> [UInt64] {
        guard instructions.count >= 2 else { return [] }
        return zip(instructions, instructions.dropFirst()).compactMap { page, add in
            materializedAddress(page, add) == address ? add.address : nil
        }
    }

    static func findSites(
        in code: [ARM64Instruction], getter: UInt64, entitlement: UInt64,
        notEntitled: UInt64, unavailable: UInt64,
        readStub: (UInt64) throws -> [ARM64Instruction],
    ) -> [Site] {
        guard code.count >= 4 else { return [] }
        var sites: [Site] = []
        for index in 1 ..< code.count - 1 {
            let call = code[index], denial = code[index - 1], gate = code[index + 1]
            guard call.mnemonic == "bl", let target = immediate(call, 0),
                  denial.mnemonic == "cbz", let denialOperands = denial.detail?.operands,
                  denialOperands.count == 2, denialOperands[0].type == .register,
                  let resultRegister = (0 ..< 31).first(where: { denialOperands[0].reg == .w($0) }),
                  let denied = immediate(denial, 1), denied > gate.address,
                  (gate.mnemonic == "tbz" || gate.mnemonic == "nop"),
                  denial.address + 4 == call.address, call.address + 4 == gate.address
            else { continue }
            if gate.mnemonic == "tbz" {
                guard let operands = gate.detail?.operands, operands.count == 3,
                      operands[0].type == .register, operands[0].reg == .w(0),
                      operands[1].type == .immediate, operands[1].imm == 0
                else { continue }
            }
            guard target == getter || (try? readStub(target)).flatMap(stubDestination) == getter else { continue }
            let lead = code[max(0, index - 24) ..< index - 1]
            guard !literalReferences(lead, to: entitlement).isEmpty else { continue }
            // The entitlement Boolean must survive the intervening release calls.
            let savedResult = lead.indices.contains { k in
                guard k > lead.startIndex, code[k].mnemonic == "mov",
                      let operands = code[k].detail?.operands, operands.count == 2
                else { return false }
                return operands[0].type == .register && operands[0].reg == .x(resultRegister)
                    && operands[1].type == .register && operands[1].reg == .x(0)
                    && code[k - 1].mnemonic == "bl"
                    && index - k <= 8
            }
            guard savedResult else { continue }
            // Both named failure paths must be in the same bounded function tail.
            // Stop at its first return, so another function cannot supply anchors.
            let tail = code.dropFirst(index + 2).prefix(512).prefix { !$0.isReturn }
            let entitlementLogs = literalReferences(tail, to: notEntitled)
            let availabilityLogs = literalReferences(tail, to: unavailable)
            guard entitlementLogs.count == 1, availabilityLogs.count == 1,
                  let entitledLog = entitlementLogs.first, let unavailableLog = availabilityLogs.first,
                  denied <= entitledLog, entitledLog < unavailableLog,
                  tail.contains(where: { $0.address == denied })
            else { continue }
            if gate.mnemonic == "tbz" {
                guard let destination = immediate(gate, 2), destination > entitledLog,
                      destination <= unavailableLog, tail.contains(where: { $0.address == destination })
                else { continue }
            }
            sites.append(Site(
                address: gate.address, before: Data(gate.bytes), replacement: ARM64.nop,
                alreadyPatched: gate.mnemonic == "nop",
            ))
        }
        return sites
    }
}
